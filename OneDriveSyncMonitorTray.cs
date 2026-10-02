using System;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Linq;
using System.Management;
using System.Text;
using System.Text.RegularExpressions;
using System.Security.Principal;
using System.Collections.Generic;
using System.Collections;
using System.Web.Script.Serialization;
using System.Windows.Forms;

internal sealed class TrayApplicationContext : ApplicationContext
{
    private readonly NotifyIcon notifyIcon;
    private readonly Timer timer;
    private readonly string installPath;
    private readonly string monitorScript;
    private readonly string statePath;
    private Process monitorProcess;
    private DashboardForm dashboard;
    private bool exiting;

    public TrayApplicationContext()
    {
        installPath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "OneDriveSyncMonitor");
        monitorScript = Path.Combine(installPath, "OneDriveSyncMonitor.ps1");
        statePath = Path.Combine(installPath, "state.json");

        var menu = new ContextMenuStrip();
        var status = new ToolStripMenuItem("Đang kiểm tra...") { Enabled = false };
        var openDashboard = new ToolStripMenuItem("Mở bảng theo dõi", null, (s, e) => ShowDashboard());
        var openLog = new ToolStripMenuItem("Mở log monitor", null, (s, e) => OpenFile(Path.Combine(installPath, "monitor.log")));
        var openFolder = new ToolStripMenuItem("Mở thư mục dữ liệu", null, (s, e) => OpenFile(installPath));
        var testAlert = new ToolStripMenuItem("Gửi test alert", null, (s, e) => {
            if (MessageBox.Show("Gửi một cảnh báo thử qua Power Automate?", "OneDrive Sync Monitor", MessageBoxButtons.YesNo, MessageBoxIcon.Question, MessageBoxDefaultButton.Button2) == DialogResult.Yes)
                RunMonitor("-TestAlert");
        });
        bool updatingEmailMenu = false;
        var emailToggle = new ToolStripMenuItem("Gửi email IT") { CheckOnClick = true, Checked = ReadItEmailEnabled() };
        emailToggle.CheckedChanged += (s, e) => {
            if (updatingEmailMenu) return;
            SetItEmail(emailToggle.Checked);
            updatingEmailMenu = true;
            emailToggle.Checked = ReadItEmailEnabled();
            updatingEmailMenu = false;
        };
        menu.Opening += (s, e) => { updatingEmailMenu = true; emailToggle.Checked = ReadItEmailEnabled(); updatingEmailMenu = false; };
        var restart = new ToolStripMenuItem("Khởi động lại monitor", null, (s, e) => { StopMonitor(); StartMonitor(); RefreshStatus(status); });
        var exitUi = new ToolStripMenuItem("Ẩn icon và tiếp tục chạy nền", null, (s, e) => ExitThread());
        var exitAll = new ToolStripMenuItem("Thoát cảnh báo và icon (tự sync vẫn chạy)", null, (s, e) => { StopMonitor(); ExitThread(); });
        menu.Items.Add(status);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(openDashboard);
        menu.Items.Add(openLog);
        menu.Items.Add(openFolder);
        menu.Items.Add(new ToolStripMenuItem("Trạng thái từng thư viện", null, (s, e) => OpenFile(Path.Combine(installPath, "libraries", "status.json"))));
        menu.Items.Add(testAlert);
        menu.Items.Add(emailToggle);
        menu.Items.Add(restart);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(exitUi);
        menu.Items.Add(exitAll);

        notifyIcon = new NotifyIcon
        {
            Icon = CreateIcon(),
            Text = "OneDrive Sync Monitor",
            Visible = true,
            ContextMenuStrip = menu
        };
        notifyIcon.DoubleClick += (s, e) => ShowDashboard();

        timer = new Timer { Interval = 10000 };
        timer.Tick += (s, e) => { RefreshStatus(status); if (dashboard != null && !dashboard.IsDisposed) dashboard.RefreshData(); };
        timer.Start();
        StartMonitor();
        RefreshStatus(status);
    }

    private void ShowDashboard()
    {
        if (dashboard == null || dashboard.IsDisposed)
        {
            dashboard = new DashboardForm(installPath, () => IsMonitorRunning(), () => IsLibrarySupervisorRunning(), () => ReadItEmailEnabled(), () => { StopMonitor(); StartMonitor(); });
            dashboard.FormClosed += (s, e) => dashboard = null;
        }
        dashboard.Show();
        if (dashboard.WindowState == FormWindowState.Minimized) dashboard.WindowState = FormWindowState.Normal;
        dashboard.BringToFront();
        dashboard.Activate();
        dashboard.RefreshData();
    }

    private void RefreshStatus(ToolStripMenuItem status)
    {
        string state = "Unknown";
        string detail = "chưa có state.json";
        try
        {
            if (File.Exists(statePath))
            {
                var text = File.ReadAllText(statePath);
                var match = Regex.Match(text, "\"Status\"\\s*:\\s*\"([^\"]+)\"", RegexOptions.IgnoreCase);
                if (!match.Success) match = Regex.Match(text, "\"status\"\\s*:\\s*\"([^\"]+)\"", RegexOptions.IgnoreCase);
                if (match.Success) state = match.Groups[1].Value;
                var time = File.GetLastWriteTime(statePath);
                detail = "cập nhật " + time.ToString("HH:mm:ss");
                if (DateTime.UtcNow - File.GetLastWriteTimeUtc(statePath) > TimeSpan.FromMinutes(5)) state = "Stale";
            }
            if (!IsMonitorRunning()) state = "Stopped";
            status.Text = "Trạng thái: " + state + " (" + detail + ")";
            notifyIcon.Text = "OneDrive: " + state;
        }
        catch { status.Text = "Trạng thái: không đọc được state.json"; }
    }

    private void StartMonitor()
    {
        if (!File.Exists(monitorScript) || IsMonitorRunning()) return;
        RunMonitor("", true);
    }

    private bool IsMonitorRunning()
    {
        try { return OwnedMonitorIds().Count > 0; }
        catch { return monitorProcess != null && !monitorProcess.HasExited; }
    }

    private List<int> OwnedMonitorIds()
    {
        return OwnedScriptIds(monitorScript);
    }

    private bool IsLibrarySupervisorRunning()
    {
        try { return OwnedScriptIds(Path.Combine(installPath, "MultiLibrarySync.ps1")).Count > 0; }
        catch { return false; }
    }

    private List<int> OwnedScriptIds(string scriptPath)
    {
        var ids = new List<int>();
        var sid = WindowsIdentity.GetCurrent().User.Value;
        using (var searcher = new ManagementObjectSearcher("SELECT * FROM Win32_Process WHERE Name='powershell.exe'"))
        using (var results = searcher.Get())
        foreach (ManagementObject item in results)
        {
            var command = item["CommandLine"] as string ?? "";
            var match = Regex.Match(command, @"(?i)(?:^|\s)-File\s+(?:""([^""]+)""|(\S+))");
            if (!match.Success) continue;
            if (Regex.IsMatch(command.Substring(0, match.Index), @"(?i)(?:^|\s)-(?:Command|EncodedCommand|C|Enc)(?:\s|$)")) continue;
            var path = match.Groups[1].Success ? match.Groups[1].Value : match.Groups[2].Value;
            if (!string.Equals(path, scriptPath, StringComparison.OrdinalIgnoreCase)) continue;
            using (var owner = item.InvokeMethod("GetOwnerSid", null, null))
                if (owner != null && (string)owner["Sid"] == sid) ids.Add(Convert.ToInt32(item["ProcessId"]));
        }
        return ids;
    }

    private void RunMonitor(string arguments, bool hidden = false)
    {
        if (!File.Exists(monitorScript)) { MessageBox.Show("Không tìm thấy monitor: " + monitorScript, "OneDrive Sync Monitor", MessageBoxButtons.OK, MessageBoxIcon.Error); return; }
        try
        {
            var ps = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell\\v1.0\\powershell.exe");
            var config = Path.Combine(installPath, "config.json");
            var args = "-NoProfile -ExecutionPolicy Bypass -File \"" + monitorScript + "\" -ConfigPath \"" + config + "\"" + (string.IsNullOrWhiteSpace(arguments) ? "" : " " + arguments);
            if (arguments == "-TestAlert")
                Process.Start(new ProcessStartInfo(ps, args) { UseShellExecute = false, CreateNoWindow = true });
            else
                monitorProcess = Process.Start(new ProcessStartInfo(ps, args) { UseShellExecute = false, CreateNoWindow = true, WindowStyle = ProcessWindowStyle.Hidden });
        }
        catch (Exception ex) { MessageBox.Show(ex.Message, "Không thể khởi động monitor", MessageBoxButtons.OK, MessageBoxIcon.Error); }
    }

    private bool ReadItEmailEnabled()
    {
        try
        {
            var config = Path.Combine(installPath, "config.json");
            if (!File.Exists(config)) return true;
            var text = File.ReadAllText(config);
            var match = Regex.Match(text, "\"NotifyItEmailEnabled\"\\s*:\\s*(true|false)", RegexOptions.IgnoreCase);
            return !match.Success || !string.Equals(match.Groups[1].Value, "false", StringComparison.OrdinalIgnoreCase);
        }
        catch { return true; }
    }

    private void SetItEmail(bool enabled)
    {
        try
        {
            var ps = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell\\v1.0\\powershell.exe");
            var switchName = enabled ? "-EnableItEmail" : "-DisableItEmail";
            var args = "-NoProfile -ExecutionPolicy Bypass -File \"" + monitorScript + "\" -ConfigPath \"" + Path.Combine(installPath, "config.json") + "\" " + switchName;
            using (var process = Process.Start(new ProcessStartInfo(ps, args) { UseShellExecute = false, CreateNoWindow = true }))
            {
                if (!process.WaitForExit(10000)) throw new TimeoutException("Lưu thiết lập quá thời gian. Kiểm tra log.");
                if (process.ExitCode != 0) throw new InvalidOperationException("Không thể lưu thiết lập email IT.");
            }
        }
        catch (Exception ex)
        {
            MessageBox.Show(ex.Message, "OneDrive Sync Monitor", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }

    private void StopMonitor()
    {
        try {
            foreach (int id in OwnedMonitorIds()) {
                using (var process = Process.GetProcessById(id)) {
                    process.Kill();
                    if (!process.WaitForExit(5000)) throw new TimeoutException("Monitor chưa dừng.");
                }
            }
        } catch (Exception ex) { MessageBox.Show(ex.Message, "Không thể dừng monitor"); }
    }

    private static void OpenFile(string path)
    {
        try { Process.Start(new ProcessStartInfo(path) { UseShellExecute = true }); } catch (Exception ex) { MessageBox.Show(ex.Message, "OneDrive Sync Monitor", MessageBoxButtons.OK, MessageBoxIcon.Error); }
    }

    internal static Icon CreateIcon()
    {
        return AppLogo.CreateIcon(32);
    }

    protected override void ExitThreadCore()
    {
        if (exiting) return;
        exiting = true;
        timer.Stop();
        notifyIcon.Visible = false;
        notifyIcon.Dispose();
        base.ExitThreadCore();
    }
}

internal sealed partial class DashboardForm : Form
{
    private readonly string installPath;
    private readonly Func<bool> monitorRunning;
    private readonly Func<bool> supervisorRunning;
    private readonly Func<bool> emailEnabled;
    private readonly Action restartMonitor;
    private readonly Label headline;
    private readonly Label summary;
    private readonly Label activity;
    private readonly Label email;
    private readonly DataGridView libraries;
    private readonly TextBox details;
    private readonly Button openLocal;
    private readonly Font statusFont;
    private readonly Bitmap logoImage;
    private readonly Dictionary<string, string> roots = new Dictionary<string, string>();
    private readonly Dictionary<string, string> urls = new Dictionary<string, string>();
    private readonly Dictionary<string, string> errors = new Dictionary<string, string>();
    public bool DataLoadSucceeded { get; private set; }
    public int LibraryCount { get { return libraries.Rows.Count; } }

    public DashboardForm(string installPath, Func<bool> monitorRunning, Func<bool> supervisorRunning, Func<bool> emailEnabled, Action restartMonitor)
    {
        this.installPath = installPath;
        this.monitorRunning = monitorRunning;
        this.supervisorRunning = supervisorRunning;
        this.emailEnabled = emailEnabled;
        this.restartMonitor = restartMonitor;
        Text = "OneDrive Sync Monitor — Bảng theo dõi";
        Icon = TrayApplicationContext.CreateIcon();
        Font = new Font("Segoe UI", 9F);
        BackColor = Color.FromArgb(246, 248, 251);
        StartPosition = FormStartPosition.CenterScreen;
        MinimumSize = new Size(800, 540);
        Size = new Size(1040, 670);
        statusFont = new Font(Font, FontStyle.Bold);

        var layout = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, RowCount = 3, Padding = new Padding(18) };
        layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 80));
        layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 82));
        layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        Controls.Add(layout);

        var header = new Panel { Dock = DockStyle.Fill, BackColor = Color.FromArgb(21, 47, 78), Padding = new Padding(18, 10, 18, 8) };
        logoImage = AppLogo.Render(52);
        var logo = new PictureBox { Image = logoImage, Location = new Point(15, 12), Size = new Size(52, 52), SizeMode = PictureBoxSizeMode.StretchImage };
        var title = new Label { Text = "OneDrive Sync Monitor", ForeColor = Color.White, Font = new Font("Segoe UI Semibold", 16F), Location = new Point(77, 8), AutoSize = true };
        headline = new Label { Text = "Đang đọc trạng thái…", ForeColor = Color.FromArgb(192, 215, 240), Font = new Font("Segoe UI", 10F), Location = new Point(79, 43), AutoSize = true };
        header.Controls.Add(logo);
        header.Controls.Add(title);
        header.Controls.Add(headline);
        layout.Controls.Add(header, 0, 0);

        var overview = new Panel { Dock = DockStyle.Fill, BackColor = Color.White, Padding = new Padding(16) };
        summary = new Label { Location = new Point(16, 9), AutoSize = true, Font = new Font("Segoe UI Semibold", 11F), ForeColor = Color.FromArgb(29, 55, 84) };
        activity = new Label { Location = new Point(16, 37), AutoSize = true, ForeColor = Color.FromArgb(75, 91, 109) };
        email = new Label { Location = new Point(16, 58), AutoSize = true, ForeColor = Color.FromArgb(75, 91, 109) };
        overview.Controls.Add(summary);
        overview.Controls.Add(activity);
        overview.Controls.Add(email);
        layout.Controls.Add(overview, 0, 1);

        var tabs = new TabControl { Dock = DockStyle.Fill, Font = new Font("Segoe UI", 10F) };
        var overviewTab = new TabPage("Tổng quan") { BackColor = Color.White };
        var overviewLayout = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, RowCount = 2, Padding = new Padding(5) };
        overviewLayout.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        overviewLayout.RowStyles.Add(new RowStyle(SizeType.Absolute, 165));
        overviewTab.Controls.Add(overviewLayout);
        tabs.TabPages.Add(overviewTab);
        layout.Controls.Add(tabs, 0, 2);

        libraries = new DataGridView {
            Dock = DockStyle.Fill, BackgroundColor = Color.White, BorderStyle = BorderStyle.None,
            ReadOnly = true, MultiSelect = false, SelectionMode = DataGridViewSelectionMode.FullRowSelect,
            AllowUserToAddRows = false, AllowUserToDeleteRows = false, AllowUserToResizeRows = false,
            RowHeadersVisible = false, AutoSizeColumnsMode = DataGridViewAutoSizeColumnsMode.Fill,
            ColumnHeadersHeight = 34, RowTemplate = { Height = 34 },
            EnableHeadersVisualStyles = false
        };
        libraries.ColumnHeadersDefaultCellStyle.BackColor = Color.FromArgb(230, 237, 245);
        libraries.ColumnHeadersDefaultCellStyle.ForeColor = Color.FromArgb(32, 55, 79);
        libraries.DefaultCellStyle.SelectionBackColor = Color.FromArgb(216, 232, 250);
        libraries.DefaultCellStyle.SelectionForeColor = Color.FromArgb(20, 40, 62);
        libraries.Columns.Add("Name", "Thư viện");
        libraries.Columns.Add("Status", "Trạng thái");
        libraries.Columns.Add("Tracked", "Đã theo dõi");
        libraries.Columns.Add("Pending", "Đang chờ");
        libraries.Columns.Add("Pushed", "Đẩy lên*");
        libraries.Columns.Add("Pulled", "Kéo về*");
        libraries.Columns.Add("Checked", "Kiểm tra lúc");
        libraries.Columns[0].FillWeight = 200;
        libraries.Columns[1].FillWeight = 145;
        libraries.Columns[6].FillWeight = 130;
        libraries.SelectionChanged += (s, e) => ShowSelection();
        overviewLayout.Controls.Add(libraries, 0, 0);

        var bottom = new Panel { Dock = DockStyle.Fill, BackColor = Color.White, Padding = new Padding(10) };
        details = new TextBox { Location = new Point(12, 9), Size = new Size(700, 95), Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right,
            Multiline = true, ReadOnly = true, BorderStyle = BorderStyle.None, BackColor = Color.White, ScrollBars = ScrollBars.Vertical,
            Text = "Chọn một thư viện để xem đường dẫn và lỗi." };
        bottom.Controls.Add(details);
        var buttons = new FlowLayoutPanel { Dock = DockStyle.Bottom, Height = 40, FlowDirection = FlowDirection.LeftToRight, WrapContents = false };
        openLocal = new Button { Text = "Mở thư mục", Width = 120, Enabled = false };
        openLocal.Click += (s, e) => { var id = SelectedId(); if (id != null && roots.ContainsKey(id)) OpenPath(roots[id]); };
        var refresh = new Button { Text = "Làm mới", Width = 95 };
        refresh.Click += (s, e) => RefreshData();
        var log = new Button { Text = "Mở log", Width = 95 };
        log.Click += (s, e) => OpenPath(Path.Combine(installPath, "monitor.log"));
        buttons.Controls.Add(openLocal);
        buttons.Controls.Add(refresh);
        buttons.Controls.Add(log);
        bottom.Controls.Add(buttons);
        overviewLayout.Controls.Add(bottom, 0, 1);
        InitializeOperationsTabs(tabs);
        RefreshData();
    }

    private static string Value(IDictionary<string, object> row, string key)
    {
        object value;
        return row != null && row.TryGetValue(key, out value) && value != null ? Convert.ToString(value) : "";
    }

    private static int Count(IDictionary<string, object> row, string key)
    {
        int count;
        return int.TryParse(Value(row, key), out count) ? count : 0;
    }

    private static string LabelFor(string status)
    {
        switch (status)
        {
            case "Monitoring": return "Đang theo dõi";
            case "Pending": return "Đang chờ";
            case "BaselineRequired": return "Cần mốc đồng bộ";
            case "NeedsReview": return "Cần xử lý";
            case "Blocked": return "Bị chặn";
            case "ReadVerified_WriteNotVerified": return "Chưa xác minh ghi";
            case "WriteVerified": return "Đã xác minh ghi";
            case "MappingMissing": return "Mất ánh xạ";
            default: return string.IsNullOrEmpty(status) ? "Chưa rõ" : status;
        }
    }

    private static Color StatusColor(string status)
    {
        if (status == "Monitoring") return Color.FromArgb(19, 116, 73);
        if (status == "NeedsReview" || status == "Blocked" || status == "MappingMissing") return Color.FromArgb(185, 45, 45);
        return Color.FromArgb(161, 105, 14);
    }

    private string SelectedId()
    {
        return libraries.SelectedRows.Count > 0 ? libraries.SelectedRows[0].Tag as string : null;
    }

    private void ShowSelection()
    {
        var id = SelectedId();
        openLocal.Enabled = id != null && roots.ContainsKey(id) && Directory.Exists(roots[id]);
        if (id == null) { details.Text = "Chọn một thư viện để xem đường dẫn và lỗi."; return; }
        var path = roots.ContainsKey(id) ? roots[id] : "";
        var url = urls.ContainsKey(id) ? urls[id] : "";
        var error = errors.ContainsKey(id) ? errors[id] : "";
        details.Text = "Máy: " + path + Environment.NewLine + "Cloud: " + url + Environment.NewLine +
            (string.IsNullOrEmpty(error) ? "Lỗi: không có trong lần kiểm tra gần nhất." : "Lỗi: " + error);
    }

    public void RefreshData()
    {
        var statusPath = Path.Combine(installPath, "libraries", "status.json");
        try
        {
            DataLoadSucceeded = false;
            bool running = monitorRunning();
            bool syncing = supervisorRunning();
            email.Text = "Email IT: " + (emailEnabled() ? "bật" : "tắt") + "  •  *Đẩy lên/kéo về là số file trong chu kỳ vừa qua, không phải tổng cộng.";
            if (!File.Exists(statusPath))
            {
                headline.Text = running && syncing ? "App đang chạy · Chưa có dữ liệu từng thư viện" : "Monitor hoặc bộ tự sync chưa chạy";
                headline.ForeColor = Color.FromArgb(255, 208, 140);
                summary.Text = "Chưa có kết quả kiểm tra thư viện";
                activity.Text = "Kiểm tra đăng nhập Graph và cấu hình thư viện.";
                libraries.Rows.Clear();
                return;
            }
            var document = new JavaScriptSerializer { MaxJsonLength = 16 * 1024 * 1024 }.DeserializeObject(File.ReadAllText(statusPath)) as IDictionary<string, object>;
            object rawLibraries;
            var items = document != null && document.TryGetValue("Libraries", out rawLibraries) ? rawLibraries as IEnumerable : null;
            var selected = SelectedId();
            roots.Clear(); urls.Clear(); errors.Clear();
            libraries.Rows.Clear();
            int total = 0, attention = 0, pending = 0, tracked = 0;
            if (items != null)
            foreach (object item in items)
            {
                var row = item as IDictionary<string, object>;
                if (row == null) continue;
                var id = Value(row, "Id");
                var state = Value(row, "Status");
                var checkedUtc = Value(row, "CheckedUtc");
                DateTime checkedTime;
                var when = DateTime.TryParse(checkedUtc, null, System.Globalization.DateTimeStyles.RoundtripKind, out checkedTime)
                    ? checkedTime.ToLocalTime().ToString("dd/MM HH:mm:ss") : "—";
                var index = libraries.Rows.Add(Value(row, "Name"), LabelFor(state), Count(row, "FilesTracked"),
                    Count(row, "Pending"), Count(row, "Pushed"), Count(row, "Pulled"), when);
                libraries.Rows[index].Tag = id;
                libraries.Rows[index].Cells[1].Style.ForeColor = StatusColor(state);
                libraries.Rows[index].Cells[1].Style.Font = statusFont;
                roots[id] = Value(row, "SourceRoot");
                urls[id] = Value(row, "LibraryWebUrl");
                errors[id] = Value(row, "Error");
                total++;
                tracked += Count(row, "FilesTracked");
                pending += Count(row, "Pending");
                if (state != "Monitoring" || !string.IsNullOrEmpty(Value(row, "Error"))) attention++;
            }
            var age = DateTime.UtcNow - File.GetLastWriteTimeUtc(statusPath);
            bool stale = age > TimeSpan.FromMinutes(5);
            bool healthy = running && syncing && !stale && attention == 0 && total > 0;
            headline.Text = !running ? "Monitor chưa chạy" : !syncing ? "Bộ tự sync thư viện chưa chạy" : stale ? "Dữ liệu đã cũ — kiểm tra tiến trình" :
                healthy ? "Các thư viện đang được theo dõi" : "Có thư viện cần chú ý";
            headline.ForeColor = healthy ? Color.FromArgb(150, 236, 188) : Color.FromArgb(255, 208, 140);
            summary.Text = total + " thư viện  ·  " + attention + " cần chú ý  ·  " + pending + " file đang chờ  ·  " + tracked + " file đã theo dõi";
            activity.Text = "Monitor: " + (running ? "đang chạy" : "đã dừng") + "  ·  Tự sync: " + (syncing ? "đang chạy" : "đã dừng") +
                "  ·  Cập nhật: " + File.GetLastWriteTime(statusPath).ToString("dd/MM/yyyy HH:mm:ss") +
                (stale ? "  (quá 5 phút)" : "") + "  ·  Tự làm mới mỗi 10 giây";
            libraries.ClearSelection();
            foreach (DataGridViewRow row in libraries.Rows)
                if (string.Equals(row.Tag as string, selected, StringComparison.Ordinal)) { row.Selected = true; break; }
            if (libraries.SelectedRows.Count == 0 && libraries.Rows.Count > 0) libraries.Rows[0].Selected = true;
            ShowSelection();
            RefreshOperationsData();
            DataLoadSucceeded = total > 0;
        }
        catch (Exception ex)
        {
            headline.Text = "Không đọc được trạng thái thư viện";
            headline.ForeColor = Color.FromArgb(255, 208, 140);
            summary.Text = "Giữ nguyên dữ liệu hiển thị gần nhất";
            activity.Text = ex.Message;
        }
    }

    private static void OpenPath(string path)
    {
        try { Process.Start(new ProcessStartInfo(path) { UseShellExecute = true }); }
        catch (Exception ex) { MessageBox.Show(ex.Message, "OneDrive Sync Monitor", MessageBoxButtons.OK, MessageBoxIcon.Error); }
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing) { statusFont.Dispose(); logoImage.Dispose(); }
        base.Dispose(disposing);
    }
}

internal static class Program
{
    [STAThread]
    private static void Main(string[] args)
    {
        if (args.Length > 0 && args[0] == "--dashboard-smoke")
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            var root = args.Length > 1 ? args[1] : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "OneDriveSyncMonitor");
            using (var form = new DashboardForm(root, () => true, () => true, () => false, () => {}))
                Environment.ExitCode = form.DataLoadSucceeded && form.LibraryCount > 0 ? 0 : 2;
            return;
        }
        bool created;
        using (var mutex = new System.Threading.Mutex(true, "OneDriveSyncMonitorTray-CurrentUser", out created))
        {
            if (!created) return;
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new TrayApplicationContext());
        }
    }
}
