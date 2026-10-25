#!/usr/bin/env python3
"""Extend the existing rename+battery ETA HardwareMonitor patch with rolling-average power.

Expected input: upstream TrafficMonitorPlugins patched by apply_patch.py and the two
Windows C++/CLI compatibility fixes. Idempotency is deliberately rejected.
"""
from pathlib import Path
import argparse


def replace_once(s: str, old: str, new: str, label: str) -> str:
    n = s.count(old)
    if n != 1:
        raise RuntimeError(f'{label}: expected one match, found {n}; source differs from pinned version')
    return s.replace(old, new, 1)


BATTERY_HISTORY_CODE = r'''
    namespace
    {
        // Samples are held in memory only. A monotonic clock avoids system-time changes.
        struct BatteryPowerSample
        {
            long long ticks;
            double watts; // signed: discharge negative, charge positive
        };

        std::deque<BatteryPowerSample> batteryPowerHistory;
        int batteryPowerState = 2; // 2 = no previous state; -1 discharge, 0 idle, +1 charge

        bool ReadBatterySignedPower(double& watts)
        {
            Computer^ computer = MonitorGlobal::Instance()->computer;
            if (computer == nullptr || !computer->IsBatteryEnabled)
                return false;

            double total = 0.0;
            bool foundBattery = false;
            for each (IHardware ^ hardware in computer->Hardware)
            {
                if (hardware->HardwareType != HardwareType::Battery)
                    continue;
                foundBattery = true;
                bool foundRate = false;
                for each (ISensor ^ sensor in hardware->Sensors)
                {
                    if (sensor->SensorType != SensorType::Power || !sensor->Value.HasValue)
                        continue;
                    const double rate = sensor->Value.Value;
                    if (!std::isfinite(rate) || rate < 0)
                        continue;
                    if (sensor->Name == L"Discharge Rate")
                    {
                        total -= rate;
                        foundRate = true;
                    }
                    else if (sensor->Name == L"Charge Rate")
                    {
                        total += rate;
                        foundRate = true;
                    }
                    else if (sensor->Name == L"Charge/Discharge Rate")
                    {
                        // LHM uses this name when the signed battery rate is zero.
                        foundRate = true;
                    }
                }
                if (!foundRate)
                    return false;
            }
            if (!foundBattery)
                return false;
            watts = total;
            return true;
        }
    }

    void CHardwareMonitorItem::ResetBatteryPowerHistory()
    {
        batteryPowerHistory.clear();
        batteryPowerState = 2;
    }

    void CHardwareMonitorItem::UpdateBatteryPowerHistory()
    {
        double watts = 0.0;
        if (!ReadBatterySignedPower(watts))
        {
            ResetBatteryPowerHistory();
            return;
        }
        const int newState = watts < -0.01 ? -1 : watts > 0.01 ? 1 : 0;
        if (newState != batteryPowerState)
        {
            batteryPowerHistory.clear(); // Never combine AC charge and battery discharge.
            batteryPowerState = newState;
        }

        const long long now = System::Diagnostics::Stopwatch::GetTimestamp();
        const long long frequency = System::Diagnostics::Stopwatch::Frequency;
        if (!batteryPowerHistory.empty())
        {
            const long long gap = now - batteryPowerHistory.back().ticks;
            if (gap < 0 || gap > frequency * 30)
                batteryPowerHistory.clear(); // Don't treat sleep/resume as measured history.
            else if (gap < frequency)
                return; // At most one sample per second.
        }

        batteryPowerHistory.push_back({ now, watts });
        // Keep up to 120 minutes so extending the configured window retains data.
        const long long cutoff = now - frequency * 120 * 60;
        while (batteryPowerHistory.size() > 1 && batteryPowerHistory[1].ticks <= cutoff)
            batteryPowerHistory.pop_front();
    }

    bool CHardwareMonitorItem::TryGetBatteryAveragePower(double& averageWatts)
    {
        if (batteryPowerHistory.empty())
            return false;
        const long long now = System::Diagnostics::Stopwatch::GetTimestamp();
        const long long frequency = System::Diagnostics::Stopwatch::Frequency;
        if (now < batteryPowerHistory.back().ticks ||
            now - batteryPowerHistory.back().ticks > frequency * 30)
            return false;

        int minutes = CHardwareMonitor::GetInstance()->m_settings.battery_average_minutes;
        if (minutes < 1) minutes = 1;
        if (minutes > 120) minutes = 120;
        const long long cutoff = now - frequency * static_cast<long long>(minutes) * 60;
        double weightedSum = 0.0;
        double totalTicks = 0.0;
        for (size_t i = 0; i < batteryPowerHistory.size(); ++i)
        {
            const long long start = (std::max)(batteryPowerHistory[i].ticks, cutoff);
            const long long end = (i + 1 < batteryPowerHistory.size())
                ? batteryPowerHistory[i + 1].ticks : now;
            if (end > start)
            {
                const double duration = static_cast<double>(end - start);
                weightedSum += duration * batteryPowerHistory[i].watts;
                totalTicks += duration;
            }
        }
        // At startup, while the first sampling interval has not yet elapsed,
        // use its current reading rather than pretending a full window exists.
        averageWatts = totalTicks > 0.0
            ? weightedSum / totalTicks : batteryPowerHistory.back().watts;
        return std::isfinite(averageWatts);
    }

    std::wstring CHardwareMonitorItem::GetBatteryAveragePowerText()
    {
        double watts = 0.0;
        if (!TryGetBatteryAveragePower(watts))
            return L"--";
        const ItemInfo& info = CHardwareMonitor::GetInstance()->m_settings.FindItemInfo(
            L"virtual/battery_average_power");
        int precision = info.decimal_places;
        if (precision < 0) precision = 0;
        if (precision > 3) precision = 3;
        std::wostringstream output;
        output << std::fixed << std::setprecision(precision) << watts;
        if (info.show_unit)
            output << L" W";
        return output.str();
    }

'''


def patch_common(s):
    return replace_once(s,
        '        bool show_mouse_tooltip{};',
        '        bool show_mouse_tooltip{};\n'
        '        int battery_average_minutes{ 10 }; // rolling time window: 1..120 min\n'
        '        bool battery_eta_use_average{}; // false = live rate; true = rolling mean',
        'CommonData.h:settings')


def patch_monitor_h(s):
    return replace_once(s, '        bool AddBatteryRemainingTimeItem();',
        '        bool AddBatteryRemainingTimeItem();\n'
        '        bool AddBatteryAveragePowerItem();', 'HardwareMonitor.h:virtual method')


def patch_monitor(s):
    s = replace_once(s,
        '    bool CHardwareMonitor::AddBatteryRemainingTimeItem()\n',
        '''    bool CHardwareMonitor::AddBatteryAveragePowerItem()
    {
        const std::wstring id = L"virtual/battery_average_power";
        if (IsDisplayItemExist(id))
            return false;
        ItemInfo info(id);
        info.unit = L"W";
        info.show_unit = true;
        info.specify_value_width = false;
        m_settings.items_info.push_back(info);
        m_item_names[id] = L"电池平均功耗";
        // Do not mutate m_items while host holds pointers; restart registers the item.
        return true;
    }

    bool CHardwareMonitor::AddBatteryRemainingTimeItem()
''', 'HardwareMonitor.cpp:AddBatteryAveragePowerItem')
    s = replace_once(s,
        '            if (item_info.identifyer == L"virtual/battery_remaining_time")',
        '''            if (item_info.identifyer == L"virtual/battery_average_power")
            {
                const std::wstring item_name = L"电池平均功耗";
                m_item_names[item_info.identifyer] = item_name;
                m_items.emplace_back(item_info.identifyer, item_name, L"平均功耗");
            }
            else if (item_info.identifyer == L"virtual/battery_remaining_time")''',
        'HardwareMonitor.cpp:LoadConfig:virtual-average')
    s = replace_once(s,
        '        m_settings.show_mouse_tooltip = ini.GetBool(L"config", L"show_mouse_tooltip", true);',
        '''        m_settings.show_mouse_tooltip = ini.GetBool(L"config", L"show_mouse_tooltip", true);
        m_settings.battery_average_minutes = ini.GetInt(L"config", L"battery_average_minutes", 10);
        if (m_settings.battery_average_minutes < 1) m_settings.battery_average_minutes = 1;
        if (m_settings.battery_average_minutes > 120) m_settings.battery_average_minutes = 120;
        m_settings.battery_eta_use_average = ini.GetBool(L"config", L"battery_eta_use_average", false);''',
        'HardwareMonitor.cpp:load-settings')
    s = replace_once(s,
        '        ini.WriteBool(L"config", L"show_mouse_tooltip", m_settings.show_mouse_tooltip);',
        '''        ini.WriteBool(L"config", L"show_mouse_tooltip", m_settings.show_mouse_tooltip);
        ini.WriteInt(L"config", L"battery_average_minutes", m_settings.battery_average_minutes);
        ini.WriteBool(L"config", L"battery_eta_use_average", m_settings.battery_eta_use_average);''',
        'HardwareMonitor.cpp:save-settings')
    s = replace_once(s,
        '            //重新获取数据\n            MonitorGlobal::Instance()->computer->Accept(MonitorGlobal::Instance()->updateVisitor);',
        '''            //重新获取数据
            MonitorGlobal::Instance()->computer->Accept(MonitorGlobal::Instance()->updateVisitor);
            CHardwareMonitorItem::UpdateBatteryPowerHistory();''',
        'HardwareMonitor.cpp:sampling-after-sensor-update')
    return s


def patch_item_h(s):
    return replace_once(s,
        '        static std::wstring GetBatteryRemainingTimeText();',
        '''        static std::wstring GetBatteryRemainingTimeText();
        static std::wstring GetBatteryAveragePowerText();
        static void UpdateBatteryPowerHistory();
        static void ResetBatteryPowerHistory();
        static bool TryGetBatteryAveragePower(double& averageWatts);''',
        'HardwareMonitorItem.h:public helpers')


def patch_item(s):
    s=replace_once(s,
        '#include <cmath>',
        '#include <cmath>\n#include <deque>\n#include <iomanip>\n#include <sstream>\n#include <algorithm>',
        'HardwareMonitorItem.cpp:includes')
    s=replace_once(s,
        'namespace HardwareMonitor\n{\n',
        'namespace HardwareMonitor\n{\n'+BATTERY_HISTORY_CODE,
        'HardwareMonitorItem.cpp:implementation')
    s=replace_once(s,
        '        if (identifier == L"virtual/battery_remaining_time")\n            return L"00h00m";',
        '''        if (identifier == L"virtual/battery_remaining_time")
            return L"00h00m";
        if (identifier == L"virtual/battery_average_power")
            return L"-00.0 W";''',
        'HardwareMonitorItem.cpp:sample')
    s=replace_once(s,
        '        // (mWh / 1000) / W = hours. Round to nearest minute.',
        '''        if (CHardwareMonitor::GetInstance()->m_settings.battery_eta_use_average)
        {
            double averageWatts = 0.0;
            if (!TryGetBatteryAveragePower(averageWatts) || averageWatts >= -0.01)
                return L"--";
            totalDischargeW = -averageWatts;
        }

        // (mWh / 1000) / W = hours. Round to nearest minute.''',
        'HardwareMonitorItem.cpp:ETA chooses rolling mean')
    s=replace_once(s,
        '''        if (identifier == L"virtual/battery_remaining_time")
        {
            item_value_main_wnd = GetBatteryRemainingTimeText();''',
        '''        if (identifier == L"virtual/battery_average_power")
        {
            item_value_main_wnd = GetBatteryAveragePowerText();
            item_value_taskbar = item_value_main_wnd;
            return;
        }
        if (identifier == L"virtual/battery_remaining_time")
        {
            item_value_main_wnd = GetBatteryRemainingTimeText();''',
        'HardwareMonitorItem.cpp:virtual average UpdateValue')
    return s


def patch_settings_h(s):
    s=replace_once(s,
        '    private: System::Windows::Forms::ToolStripMenuItem^ addBatteryTimeMenuItem;',
        '''    private: System::Windows::Forms::ToolStripMenuItem^ addBatteryTimeMenuItem;
    private: System::Windows::Forms::ToolStripMenuItem^ addBatteryAverageMenuItem;
    private: System::Windows::Forms::ToolStripMenuItem^ batteryAverageSettingsMenuItem;''',
        'SettingsForm.h:menu fields')
    s=replace_once(s,
        '        void AddBatteryTimeClicked(Object^ sender, EventArgs^ e);',
        '''        void AddBatteryTimeClicked(Object^ sender, EventArgs^ e);
        void AddBatteryAverageClicked(Object^ sender, EventArgs^ e);
        void ConfigureBatteryAverageClicked(Object^ sender, EventArgs^ e);''',
        'SettingsForm.h:menu methods')
    return s


SETTINGS_METHODS=r'''
    void SettingsForm::AddBatteryAverageClicked(Object^ sender, EventArgs^ e)
    {
        if (!CHardwareMonitor::GetInstance()->AddBatteryAveragePowerItem())
            return;
        batteryCheck->Checked = true;
        MonitorGlobal::Instance()->computer->IsBatteryEnabled = true;
        CHardwareMonitor::GetInstance()->SaveConfig();
        RefreshRenameSelection(monitorItemListBox->Items->Count);
        MessageBox::Show(L"电池平均功耗已加入。请重启 TrafficMonitor 使新监控项生效。",
                         L"HardwareMonitor", MessageBoxButtons::OK, MessageBoxIcon::Information);
    }

    void SettingsForm::ConfigureBatteryAverageClicked(Object^ sender, EventArgs^ e)
    {
        auto& settings = CHardwareMonitor::GetInstance()->m_settings;
        System::Windows::Forms::Form^ dialog = gcnew System::Windows::Forms::Form();
        dialog->Text = L"电池平均功耗与剩余时间设置";
        dialog->StartPosition = System::Windows::Forms::FormStartPosition::CenterParent;
        dialog->FormBorderStyle = System::Windows::Forms::FormBorderStyle::FixedDialog;
        dialog->MaximizeBox = false;
        dialog->MinimizeBox = false;
        dialog->ShowInTaskbar = false;
        dialog->ClientSize = System::Drawing::Size(450, 226);

        System::Windows::Forms::Label^ windowLabel = gcnew System::Windows::Forms::Label();
        windowLabel->Text = L"平均功耗统计窗口（分钟，1 至 120）：";
        windowLabel->AutoSize = true;
        windowLabel->Location = System::Drawing::Point(14, 18);

        System::Windows::Forms::NumericUpDown^ windowBox = gcnew System::Windows::Forms::NumericUpDown();
        windowBox->Minimum = System::Decimal(1);
        windowBox->Maximum = System::Decimal(120);
        windowBox->Value = System::Decimal(settings.battery_average_minutes);
        windowBox->Location = System::Drawing::Point(324, 15);
        windowBox->Size = System::Drawing::Size(105, 26);

        System::Windows::Forms::Label^ modeLabel = gcnew System::Windows::Forms::Label();
        modeLabel->Text = L"电池剩余时间的计算依据：";
        modeLabel->AutoSize = true;
        modeLabel->Location = System::Drawing::Point(14, 65);

        System::Windows::Forms::RadioButton^ liveRadio = gcnew System::Windows::Forms::RadioButton();
        liveRadio->Text = L"实时放电功率（当前值）";
        liveRadio->AutoSize = true;
        liveRadio->Location = System::Drawing::Point(28, 94);
        liveRadio->Checked = !settings.battery_eta_use_average;

        System::Windows::Forms::RadioButton^ averageRadio = gcnew System::Windows::Forms::RadioButton();
        averageRadio->Text = L"过去指定分钟的平均放电功率";
        averageRadio->AutoSize = true;
        averageRadio->Location = System::Drawing::Point(28, 121);
        averageRadio->Checked = settings.battery_eta_use_average;

        System::Windows::Forms::Button^ ok = gcnew System::Windows::Forms::Button();
        ok->Text = L"确定";
        ok->Location = System::Drawing::Point(256, 177);
        ok->Size = System::Drawing::Size(80, 28);
        ok->DialogResult = System::Windows::Forms::DialogResult::OK;
        System::Windows::Forms::Button^ cancel = gcnew System::Windows::Forms::Button();
        cancel->Text = L"取消";
        cancel->Location = System::Drawing::Point(349, 177);
        cancel->Size = System::Drawing::Size(80, 28);
        cancel->DialogResult = System::Windows::Forms::DialogResult::Cancel;

        dialog->Controls->Add(windowLabel);
        dialog->Controls->Add(windowBox);
        dialog->Controls->Add(modeLabel);
        dialog->Controls->Add(liveRadio);
        dialog->Controls->Add(averageRadio);
        dialog->Controls->Add(ok);
        dialog->Controls->Add(cancel);
        dialog->AcceptButton = ok;
        dialog->CancelButton = cancel;
        if (dialog->ShowDialog(this) == System::Windows::Forms::DialogResult::OK)
        {
            settings.battery_average_minutes = System::Decimal::ToInt32(windowBox->Value);
            settings.battery_eta_use_average = averageRadio->Checked;
            CHardwareMonitor::GetInstance()->SaveConfig();
            UpdateItemsValue();
        }
        delete dialog;
    }

'''


def patch_settings_cpp(s):
    s=replace_once(s,
        '        addBatteryTimeMenuItem = gcnew ToolStripMenuItem(L"添加电池剩余时间（计算）");',
        '''        addBatteryTimeMenuItem = gcnew ToolStripMenuItem(L"添加电池剩余时间（计算）");
        addBatteryAverageMenuItem = gcnew ToolStripMenuItem(L"添加电池平均功耗（计算）");
        batteryAverageSettingsMenuItem = gcnew ToolStripMenuItem(L"平均功耗窗口及续航方式设置...");''',
        'SettingsForm.cpp:add menu objects')
    s=replace_once(s,
        '        renameContextMenu->Items->Add(addBatteryTimeMenuItem);',
        '''        renameContextMenu->Items->Add(addBatteryTimeMenuItem);
        renameContextMenu->Items->Add(addBatteryAverageMenuItem);
        renameContextMenu->Items->Add(gcnew ToolStripSeparator());
        renameContextMenu->Items->Add(batteryAverageSettingsMenuItem);''',
        'SettingsForm.cpp:menu layout')
    s=replace_once(s,
        '        addBatteryTimeMenuItem->Click += gcnew EventHandler(this, &SettingsForm::AddBatteryTimeClicked);',
        '''        addBatteryTimeMenuItem->Click += gcnew EventHandler(this, &SettingsForm::AddBatteryTimeClicked);
        addBatteryAverageMenuItem->Click += gcnew EventHandler(this, &SettingsForm::AddBatteryAverageClicked);
        batteryAverageSettingsMenuItem->Click += gcnew EventHandler(this, &SettingsForm::ConfigureBatteryAverageClicked);''',
        'SettingsForm.cpp:menu callbacks')
    s=replace_once(s,
        '''        addBatteryTimeMenuItem->Enabled =
            !CHardwareMonitor::GetInstance()->IsDisplayItemExist(L"virtual/battery_remaining_time");''',
        '''        addBatteryTimeMenuItem->Enabled =
            !CHardwareMonitor::GetInstance()->IsDisplayItemExist(L"virtual/battery_remaining_time");
        addBatteryAverageMenuItem->Enabled =
            !CHardwareMonitor::GetInstance()->IsDisplayItemExist(L"virtual/battery_average_power");''',
        'SettingsForm.cpp:enable menu')
    s=replace_once(s,
        '    void SettingsForm::AddBatteryTimeClicked(Object^ sender, EventArgs^ e)',
        SETTINGS_METHODS + '    void SettingsForm::AddBatteryTimeClicked(Object^ sender, EventArgs^ e)',
        'SettingsForm.cpp:configure window')
    s=replace_once(s,
        '''            if (listItem != nullptr && listItem->sensor == nullptr &&
                listItem->identifier != nullptr &&
                listItem->identifier->Equals(L"virtual/battery_remaining_time"))''',
        '''            if (listItem != nullptr && listItem->sensor == nullptr &&
                listItem->identifier != nullptr &&
                listItem->identifier->Equals(L"virtual/battery_average_power"))
            {
                listItem->displayValue = gcnew String(CHardwareMonitorItem::GetBatteryAveragePowerText().c_str());
            }
            if (listItem != nullptr && listItem->sensor == nullptr &&
                listItem->identifier != nullptr &&
                listItem->identifier->Equals(L"virtual/battery_remaining_time"))''',
        'SettingsForm.cpp:UpdateItemsValue')
    s=replace_once(s,
        '''                if (item.identifyer == L"virtual/battery_remaining_time")''',
        '''                if (item.identifyer == L"virtual/battery_average_power")
                {
                    listItem->displayValue = gcnew String(CHardwareMonitorItem::GetBatteryAveragePowerText().c_str());
                    monitorItemListBox->Items->Add(listItem);
                }
                else if (item.identifyer == L"virtual/battery_remaining_time")''',
        'SettingsForm.cpp:UpdateItemList')
    return s


PATCHES={
    'CommonData.h':patch_common,
    'HardwareMonitor.h':patch_monitor_h,
    'HardwareMonitor.cpp':patch_monitor,
    'HardwareMonitorItem.h':patch_item_h,
    'HardwareMonitorItem.cpp':patch_item,
    'SettingsForm.h':patch_settings_h,
    'SettingsForm.cpp':patch_settings_cpp,
}


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('source',type=Path,help='Previously patched TrafficMonitorPlugins tree')
    args=parser.parse_args()
    base=args.source/'Plugins'/'HardwareMonitor'
    prepared={}
    for name,func in PATCHES.items():
        file=base/name
        original=file.read_bytes()
        bom=b'\xef\xbb\xbf' if original.startswith(b'\xef\xbb\xbf') else b''
        src=original[len(bom):].decode('utf-8').replace('\r\n','\n')
        if 'battery_average_minutes' in src and name in ('CommonData.h','HardwareMonitor.cpp'):
            raise RuntimeError(f'{name}: patch already applied')
        patched=func(src)
        if not patched or patched==src:
            raise RuntimeError(f'{name}: patch had no effect')
        crlf=b'\r\n' in original
        prepared[file] = bom+(patched.replace('\n','\r\n') if crlf else patched).encode('utf-8')
    for file,payload in prepared.items():
        file.write_bytes(payload)
        print('Patched',file)
    print('Battery average power and ETA selection changes applied to',len(prepared),'files')


if __name__=='__main__':
    main()