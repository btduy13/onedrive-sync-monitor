using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Text;
using System.Web.Script.Serialization;
using System.Windows.Forms;

internal sealed partial class DashboardForm
{
    private DataGridView queueGrid;
    private Label queueSummary;
    private Label configSummary;
    private TextBox machineLabel;
    private TextBox webhookInput;
    private TextBox logText;
    private Button emailButton, updateButton, recoveryButton, syncButton;
    private string selectedPendingPath;
    private bool isRefreshingOperations;

    private static Button ActionButton(string title, EventHandler handler, int width = 145)
    {
        var button = new Button { Text = title, Width = width, Height = 31, Margin = new Padding(5) };
        button.Click += handler;
        return button;
    }

    private static FlowLayoutPanel ActionRow()
    {
        return new FlowLayoutPanel { Dock = DockStyle.Top, Height = 45, FlowDirection = FlowDirection.LeftToRight, WrapContents = false, AutoScroll = true };
    }

    private void InitializeOperationsTabs(TabControl tabs)
    {
        var queueTab = new TabPage("Hàng đợi") { BackColor = Color.White, Padding = new Padding(10) };
        queueSummary = new Label { Dock = DockStyle.Top, Height = 48, ForeColor = Color.FromArgb(75, 91, 109),
            Text = "Chọn thư viện ở tab Tổng quan để xem file đang chờ. Chờ không đồng nghĩa với lỗi." };
        queueGrid = new DataGridView { Dock = DockStyle.Fill, ReadOnly = true, MultiSelect = false,
            AllowUserToAddRows = false, AllowUserToDeleteRows = false, RowHeadersVisible = false,
            SelectionMode = DataGridViewSelectionMode.FullRowSelect, AutoSizeColumnsMode = DataGridViewAutoSizeColumnsMode.Fill,
            BackgroundColor = Color.White, BorderStyle = BorderStyle.None };
        queueGrid.Columns.Add("Path", "File / đường dẫn tương đối");
        queueGrid.Columns.Add("Baseline", "Mốc");
        queueGrid.Columns.Add("Local", "Trên máy");
        queueGrid.Columns.Add("Modified", "Sửa lúc");
        queueGrid.Columns[0].FillWeight = 330;
        queueGrid.Columns[1].FillWeight = 90;
        queueGrid.Columns[2].FillWeight = 95;
        queueGrid.Columns[3].FillWeight = 125;
        queueGrid.SelectionChanged += (s, e) => selectedPendingPath = queueGrid.SelectedRows.Count > 0 ? queueGrid.SelectedRows[0].Tag as string : null;
        var queueActions = ActionRow();
        queueActions.Controls.Add(ActionButton("Làm mới hàng đợi", (s, e) => RefreshQueue(), 150));
        queueActions.Controls.Add(ActionButton("Mở trên máy", (s, e) => OpenPendingLocal(), 120));
        queueActions.Controls.Add(ActionButton("Đẩy máy → cloud", (s, e) => ResolveSelected("ResolveLocal"), 145));
        queueActions.Controls.Add(ActionButton("Kéo cloud → máy", (s, e) => ResolveSelected("ResolveCloud"), 145));
        queueTab.Controls.Add(queueGrid);
        queueTab.Controls.Add(queueActions);
        queueTab.Controls.Add(queueSummary);
        tabs.TabPages.Add(queueTab);

        var controlsTab = new TabPage("Điều khiển") { BackColor = Color.White, Padding = new Padding(16), AutoScroll = true };
        var controlStack = new FlowLayoutPanel { Dock = DockStyle.Fill, FlowDirection = FlowDirection.TopDown, WrapContents = false, AutoScroll = true };
        controlStack.Controls.Add(new Label { Text = "SYNC VÀ QUYỀN GRAPH", Width = 800, Height = 28, Font = new Font(Font, FontStyle.Bold), ForeColor = Color.FromArgb(29, 55, 84) });
        var syncActions = ActionRow(); syncActions.Width = 830;
        syncButton = ActionButton("Dừng tự sync", (s, e) => ToggleSync(), 130);
        syncActions.Controls.Add(syncButton);
        syncActions.Controls.Add(ActionButton("Đăng nhập Graph", (s, e) => RunVisibleAction("SignIn"), 145));
        syncActions.Controls.Add(ActionButton("Xác minh quyền ghi", (s, e) => VerifyWrite(), 165));
        syncActions.Controls.Add(ActionButton("Khởi động lại monitor", (s, e) => { restartMonitor(); RefreshData(); }, 180));
        controlStack.Controls.Add(syncActions);
        controlStack.Controls.Add(new Label { Text = "Đăng nhập và kiểm tra quyền mở cửa sổ PowerShell để bạn xác nhận tài khoản. Bộ tự sync được tạm dừng rồi khôi phục sau khi thao tác xong.", Width = 850, Height = 48, ForeColor = Color.FromArgb(75, 91, 109) });
        controlStack.Controls.Add(new Label { Text = "CẢNH BÁO VÀ TÙY CHỌN", Width = 800, Height = 28, Font = new Font(Font, FontStyle.Bold), ForeColor = Color.FromArgb(29, 55, 84) });
        var alertActions = ActionRow(); alertActions.Width = 830;
        emailButton = ActionButton("Email IT: —", (s, e) => TogglePreference("Email", "email IT"), 145);
        updateButton = ActionButton("Tự cập nhật: —", (s, e) => TogglePreference("AutoUpdate", "tự cập nhật"), 160);
        recoveryButton = ActionButton("Tự khắc phục: —", (s, e) => TogglePreference("SafeRecovery", "tự khắc phục an toàn"), 180);
        alertActions.Controls.Add(emailButton); alertActions.Controls.Add(updateButton); alertActions.Controls.Add(recoveryButton);
        alertActions.Controls.Add(ActionButton("Gửi cảnh báo thử", (s, e) => SendTestAlert(), 165));
        controlStack.Controls.Add(alertActions);
        configSummary = new Label { Width = 850, Height = 48, ForeColor = Color.FromArgb(75, 91, 109) };
        controlStack.Controls.Add(configSummary);
        controlsTab.Controls.Add(controlStack);
        tabs.TabPages.Add(controlsTab);

        var settingsTab = new TabPage("Thiết lập") { BackColor = Color.White, Padding = new Padding(16), AutoScroll = true };
        var settings = new FlowLayoutPanel { Dock = DockStyle.Fill, FlowDirection = FlowDirection.TopDown, WrapContents = false, AutoScroll = true };
        settings.Controls.Add(new Label { Text = "TÊN MÁY HIỂN THỊ TRONG CẢNH BÁO", Width = 800, Height = 27, Font = new Font(Font, FontStyle.Bold) });
        var machineRow = ActionRow(); machineRow.Width = 830;
        machineLabel = new TextBox { Width = 380, Margin = new Padding(5, 8, 5, 5) };
        machineRow.Controls.Add(machineLabel);
        machineRow.Controls.Add(ActionButton("Lưu tên máy", (s, e) => SaveMachineName(), 120));
        settings.Controls.Add(machineRow);
        settings.Controls.Add(new Label { Text = "POWER AUTOMATE WEBHOOK · URL được mã hóa cho tài khoản Windows hiện tại và không hiện lại trong ứng dụng.", Width = 850, Height = 46, ForeColor = Color.FromArgb(75, 91, 109) });
        var webhookRow = ActionRow(); webhookRow.Width = 830;
        webhookInput = new TextBox { Width = 385, Margin = new Padding(5, 8, 5, 5), UseSystemPasswordChar = true };
        webhookRow.Controls.Add(webhookInput);
        webhookRow.Controls.Add(ActionButton("Lưu URL mới", (s, e) => SaveWebhook(), 125));
        webhookRow.Controls.Add(ActionButton("Xóa URL", (s, e) => ClearWebhook(), 100));
        settings.Controls.Add(webhookRow);
        settings.Controls.Add(new Label { Text = "Gửi cảnh báo thử chỉ có hiệu lực khi URL hợp lệ. Chỉ bật email IT khi bạn muốn Power Automate gửi email.", Width = 850, Height = 47, ForeColor = Color.FromArgb(75, 91, 109) });
        settings.Controls.Add(ActionButton("Mở thư mục cấu hình", (s, e) => OpenPath(installPath), 180));
        settingsTab.Controls.Add(settings);
        tabs.TabPages.Add(settingsTab);

        var logTab = new TabPage("Nhật ký") { BackColor = Color.White, Padding = new Padding(10) };
        logText = new TextBox { Dock = DockStyle.Fill, Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Both,
            WordWrap = false, Font = new Font("Consolas", 9F), BackColor = Color.FromArgb(249, 251, 253) };
        var logActions = ActionRow();
        logActions.Controls.Add(ActionButton("Làm mới log", (s, e) => RefreshLog(), 120));
        logActions.Controls.Add(ActionButton("Mở file log", (s, e) => OpenPath(Path.Combine(installPath, "monitor.log")), 120));
        logActions.Controls.Add(ActionButton("Mở dữ liệu trạng thái", (s, e) => OpenPath(Path.Combine(installPath, "libraries", "status.json")), 185));
        logTab.Controls.Add(logText); logTab.Controls.Add(logActions);
        tabs.TabPages.Add(logTab);
        tabs.SelectedIndexChanged += (s, e) => { if (tabs.SelectedTab == queueTab) RefreshQueue(); if (tabs.SelectedTab == logTab) RefreshLog(); };
        libraries.SelectionChanged += (s, e) => { if (queueGrid != null && !isRefreshingOperations) RefreshQueue(); };
    }

    private IDictionary<string, object> ReadJson(string path)
    {
        if (!File.Exists(path)) return null;
        return new JavaScriptSerializer { MaxJsonLength = 16 * 1024 * 1024 }.DeserializeObject(File.ReadAllText(path)) as IDictionary<string, object>;
    }

    private bool ConfigFlag(string name)
    {
        var config = ReadJson(Path.Combine(installPath, "config.json"));
        object value;
        return config != null && config.TryGetValue(name, out value) && value != null && Convert.ToBoolean(value);
    }

    private void RefreshOperationsData()
    {
        if (isRefreshingOperations) return;
        isRefreshingOperations = true;
        try
        {
            var config = ReadJson(Path.Combine(installPath, "config.json"));
            bool mail = ConfigFlag("NotifyItEmailEnabled"), updates = ConfigFlag("AutoUpdateEnabled"), recovery = ConfigFlag("SafeRecoveryEnabled");
            emailButton.Text = "Email IT: " + (mail ? "bật" : "tắt");
            updateButton.Text = "Tự cập nhật: " + (updates ? "bật" : "tắt");
            recoveryButton.Text = "Tự khắc phục: " + (recovery ? "bật" : "tắt");
            syncButton.Text = supervisorRunning() ? "Dừng tự sync" : "Bật tự sync";
            var configured = !string.IsNullOrWhiteSpace(Value(config, "WebhookUrlProtected")) || !string.IsNullOrWhiteSpace(Value(config, "WebhookUrl"));
            configSummary.Text = "Webhook: " + (configured ? "đã lưu" : "chưa thiết lập") +
                "  ·  Email IT: " + (mail ? "bật" : "tắt") + "  ·  Tên máy cảnh báo: " + Value(config, "ComputerName");
            if (!machineLabel.Focused) machineLabel.Text = Value(config, "ComputerName");
            RefreshQueue();
        }
        catch (Exception ex) { configSummary.Text = "Không đọc được thiết lập: " + ex.Message; }
        finally { isRefreshingOperations = false; }
    }

    private void RefreshQueue()
    {
        if (queueGrid == null) return;
        var id = SelectedId();
        var oldPath = selectedPendingPath;
        queueGrid.Rows.Clear();
        selectedPendingPath = null;
        if (id == null || !roots.ContainsKey(id)) { queueSummary.Text = "Chọn thư viện ở tab Tổng quan để xem file đang chờ."; return; }
        try
        {
            var state = ReadJson(Path.Combine(installPath, "libraries", id, "state.json"));
            object pendingRaw, filesRaw;
            var pending = state != null && state.TryGetValue("PendingPaths", out pendingRaw) ? pendingRaw as IEnumerable : null;
            var files = state != null && state.TryGetValue("Files", out filesRaw) ? filesRaw as IDictionary<string, object> : null;
            int known = 0, withoutBaseline = 0;
            if (pending != null)
            foreach (object raw in pending)
            {
                var path = Convert.ToString(raw);
                if (string.IsNullOrWhiteSpace(path)) continue;
                bool baseline = files != null && files.ContainsKey(path);
                var full = Path.GetFullPath(Path.Combine(roots[id], path));
                bool safe = full.StartsWith(Path.GetFullPath(roots[id]).TrimEnd('\\') + "\\", StringComparison.OrdinalIgnoreCase);
                var local = safe && File.Exists(full) ? new FileInfo(full) : null;
                int index = queueGrid.Rows.Add(path, baseline ? "Đã theo dõi" : "Chưa có", local == null ? "Không có sẵn" : "Có file",
                    local == null ? "—" : local.LastWriteTime.ToString("dd/MM HH:mm:ss"));
                queueGrid.Rows[index].Tag = path;
                if (baseline) known++; else withoutBaseline++;
            }
            queueSummary.Text = Value(ReadJson(Path.Combine(installPath, "libraries", id, "status.json")), "Name") +
                ": " + queueGrid.Rows.Count + " mục chờ  ·  " + withoutBaseline + " chưa có mốc  ·  " + known +
                " đã theo dõi. Đây là hàng đợi kiểm tra, không phải số file chắc chắn sync lỗi.";
            queueGrid.ClearSelection();
            foreach (DataGridViewRow row in queueGrid.Rows)
                if (string.Equals(row.Tag as string, oldPath, StringComparison.Ordinal)) { row.Selected = true; break; }
            if (queueGrid.SelectedRows.Count == 0 && queueGrid.Rows.Count > 0) queueGrid.Rows[0].Selected = true;
        }
        catch (Exception ex) { queueSummary.Text = "Không đọc được hàng đợi: " + ex.Message; }
    }

    private void OpenPendingLocal()
    {
        var id = SelectedId();
        if (id == null || selectedPendingPath == null || !roots.ContainsKey(id)) return;
        var full = Path.GetFullPath(Path.Combine(roots[id], selectedPendingPath));
        if (!full.StartsWith(Path.GetFullPath(roots[id]).TrimEnd('\\') + "\\", StringComparison.OrdinalIgnoreCase)) return;
        OpenPath(File.Exists(full) ? full : Path.GetDirectoryName(full));
    }

    private void ResolveSelected(string action)
    {
        var id = SelectedId(); var path = selectedPendingPath;
        if (id == null || string.IsNullOrWhiteSpace(path)) { MessageBox.Show("Chọn một file đang chờ trước."); return; }
        string direction = action == "ResolveLocal" ? "MÁY → CLOUD" : "CLOUD → MÁY";
        var warning = "Chỉ xử lý file này:\n" + path + "\n\nChiều ưu tiên: " + direction +
            "\nPhiên bản ở phía còn lại có thể bị thay thế. Hãy xác nhận bạn đã kiểm tra nội dung trước khi tiếp tục.";
        if (MessageBox.Show(warning, "Xác nhận xử lý thủ công", MessageBoxButtons.YesNo, MessageBoxIcon.Warning, MessageBoxDefaultButton.Button2) != DialogResult.Yes) return;
        RunVisibleAction(action, id, path);
    }

    private void VerifyWrite()
    {
        var id = SelectedId();
        if (id == null) { MessageBox.Show("Chọn thư viện ở tab Tổng quan trước."); return; }
        if (MessageBox.Show("Kiểm tra quyền ghi sẽ tạo một file thử riêng trên thư viện đã chọn. Tiếp tục?", "Xác minh quyền Graph", MessageBoxButtons.YesNo, MessageBoxIcon.Question) != DialogResult.Yes) return;
        RunVisibleAction("VerifyWrite", id);
    }

    private string HelperPath { get { return Path.Combine(installPath, "Manage-OneDriveSyncMonitorUi.ps1"); } }
    private static string Quote(string text) { return "\"" + text.Replace("\"", "") + "\""; }

    private ProcessStartInfo ActionProcess(string action, string extra = "")
    {
        if (!File.Exists(HelperPath)) throw new FileNotFoundException("Thiếu bộ điều khiển UI; hãy cài lại bản mới.", HelperPath);
        var ps = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell\\v1.0\\powershell.exe");
        return new ProcessStartInfo(ps, "-NoProfile -ExecutionPolicy Bypass -File " + Quote(HelperPath) + " -Action " + action + extra)
            { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
    }

    private void RunAction(string action, string extra = "", string secret = null)
    {
        try
        {
            var start = ActionProcess(action, extra);
            if (secret != null) start.RedirectStandardInput = true;
            using (var process = Process.Start(start))
            {
                if (secret != null) { process.StandardInput.WriteLine(secret); process.StandardInput.Close(); }
                if (!process.WaitForExit(30000)) throw new TimeoutException("Thao tác chưa kết thúc sau 30 giây. Kiểm tra log trước khi thử lại.");
                var output = process.StandardOutput.ReadToEnd();
                var error = process.StandardError.ReadToEnd();
                if (process.ExitCode != 0) throw new InvalidOperationException(string.IsNullOrWhiteSpace(error) ? output : error);
                MessageBox.Show(string.IsNullOrWhiteSpace(output) ? "Đã hoàn tất." : output.Trim(), "OneDrive Sync Monitor", MessageBoxButtons.OK, MessageBoxIcon.Information);
            }
            RefreshData();
        }
        catch (Exception ex) { MessageBox.Show(ex.Message, "Thao tác không thành công", MessageBoxButtons.OK, MessageBoxIcon.Error); }
    }

    private void RunVisibleAction(string action, string id = null, string path = null)
    {
        try
        {
            var start = ActionProcess(action,
                (id == null ? "" : " -LibraryId " + Quote(id)) +
                (path == null ? "" : " -RelativePath " + Quote(path) + " -ConfirmDirection " + (action == "ResolveLocal" ? "LocalToCloud" : "CloudToLocal")));
            start.Arguments = "-NoExit " + start.Arguments;
            start.CreateNoWindow = false;
            start.RedirectStandardOutput = false; start.RedirectStandardError = false;
            Process.Start(start);
            MessageBox.Show("Đã mở cửa sổ PowerShell để thực hiện. Xem kết quả trong cửa sổ đó rồi quay lại Làm mới.", "OneDrive Sync Monitor");
        }
        catch (Exception ex) { MessageBox.Show(ex.Message, "Không mở được thao tác", MessageBoxButtons.OK, MessageBoxIcon.Error); }
    }

    private void ToggleSync()
    {
        bool running = supervisorRunning();
        if (MessageBox.Show(running ? "Tạm dừng tự sync cho tài khoản Windows này?" : "Bật lại tự sync cho tài khoản Windows này?",
            "Điều khiển tự sync", MessageBoxButtons.YesNo, MessageBoxIcon.Question) != DialogResult.Yes) return;
        RunAction(running ? "StopSync" : "StartSync");
    }

    private void TogglePreference(string name, string title)
    {
        string property = name == "Email" ? "NotifyItEmailEnabled" : name == "AutoUpdate" ? "AutoUpdateEnabled" : "SafeRecoveryEnabled";
        bool next = !ConfigFlag(property);
        if (MessageBox.Show((next ? "Bật " : "Tắt ") + title + "?", "Xác nhận thiết lập", MessageBoxButtons.YesNo, MessageBoxIcon.Question) != DialogResult.Yes) return;
        RunAction("SetPreference", " -Name " + name + " -Value " + (next ? "true" : "false"));
    }

    private void SendTestAlert()
    {
        if (MessageBox.Show("Gửi một cảnh báo thử qua Power Automate? Nếu email IT đang bật, IT cũng sẽ nhận thư thử.",
            "Gửi cảnh báo thử", MessageBoxButtons.YesNo, MessageBoxIcon.Question, MessageBoxDefaultButton.Button2) != DialogResult.Yes) return;
        RunAction("TestAlert");
    }

    private void SaveMachineName()
    {
        var value = machineLabel.Text.Trim();
        if (!System.Text.RegularExpressions.Regex.IsMatch(value, @"^[\p{L}\p{N}_.-]{1,64}$")) { MessageBox.Show("Tên máy phải dài 1–64 ký tự: chữ, số, dấu chấm, gạch ngang hoặc gạch dưới."); return; }
        RunAction("SetPreference", " -Name ComputerName -Value " + Quote(value));
    }

    private void SaveWebhook()
    {
        var url = webhookInput.Text.Trim();
        Uri parsed;
        if (!Uri.TryCreate(url, UriKind.Absolute, out parsed) || parsed.Scheme != "https" || !string.IsNullOrEmpty(parsed.UserInfo))
        { MessageBox.Show("Dán URL HTTPS đầy đủ từ Power Automate."); return; }
        RunAction("SetWebhook", "", url);
        webhookInput.Clear();
    }

    private void ClearWebhook()
    {
        if (MessageBox.Show("Xóa webhook đã lưu? App sẽ không gửi cảnh báo ra ngoài cho đến khi có URL mới.",
            "Xóa webhook", MessageBoxButtons.YesNo, MessageBoxIcon.Warning, MessageBoxDefaultButton.Button2) != DialogResult.Yes) return;
        RunAction("ClearWebhook");
    }

    private void RefreshLog()
    {
        try
        {
            var path = Path.Combine(installPath, "monitor.log");
            if (!File.Exists(path)) { logText.Text = "Chưa có monitor.log"; return; }
            var lines = File.ReadAllLines(path);
            logText.Lines = lines.Skip(Math.Max(0, lines.Length - 250)).ToArray();
            logText.SelectionStart = logText.TextLength;
            logText.ScrollToCaret();
        }
        catch (Exception ex) { logText.Text = "Không đọc được log: " + ex.Message; }
    }
}
