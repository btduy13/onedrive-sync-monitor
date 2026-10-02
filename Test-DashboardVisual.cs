using System;
using System.IO;
using System.Reflection;
using System.Drawing;
using System.Drawing.Imaging;
using System.Windows.Forms;

internal static class DashboardVisualTest
{
    [STAThread]
    private static int Main(string[] args)
    {
        if (args.Length < 1 || args.Length > 4) return 2;
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        var installPath = args.Length >= 2 ? args[1] : args[0];
        var assembly = Assembly.LoadFrom(Path.Combine(args[0], "OneDriveSyncMonitorTray.exe"));
        var type = assembly.GetType("DashboardForm", true);
        var form = (Form)Activator.CreateInstance(type, BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic,
            null, new object[] { installPath, new Func<bool>(() => true), new Func<bool>(() => true), new Func<bool>(() => false), new Action(() => {}) }, null);
        try
        {
            form.Show();
            Application.DoEvents();
            var loaded = (bool)type.GetProperty("DataLoadSucceeded").GetValue(form, null);
            var rows = (int)type.GetProperty("LibraryCount").GetValue(form, null);
            var tabs = FindTabs(form);
            var queue = (DataGridView)type.GetField("queueGrid", BindingFlags.NonPublic | BindingFlags.Instance).GetValue(form);
            var email = (Button)type.GetField("emailButton", BindingFlags.NonPublic | BindingFlags.Instance).GetValue(form);
            var libraryGrid = (DataGridView)type.GetField("libraries", BindingFlags.NonPublic | BindingFlags.Instance).GetValue(form);
            libraryGrid.ClearSelection();
            foreach (DataGridViewRow row in libraryGrid.Rows)
                if (Convert.ToString(row.Cells[0].Value).StartsWith("OneDrive -")) { row.Selected = true; break; }
            type.GetMethod("RefreshQueue", BindingFlags.NonPublic | BindingFlags.Instance).Invoke(form, null);
            using (var icon = Icon.ExtractAssociatedIcon(Path.Combine(args[0], "OneDriveSyncMonitorTray.exe")))
                if (icon == null) return 3;
            if (args.Length == 4) { tabs.SelectedIndex = int.Parse(args[3]); Application.DoEvents(); }
            if (args.Length >= 3)
            {
                using (var screenshot = new Bitmap(form.Width, form.Height))
                {
                    form.DrawToBitmap(screenshot, new Rectangle(0, 0, form.Width, form.Height));
                    screenshot.Save(args[2], ImageFormat.Png);
                }
            }
            Console.WriteLine("Visible=" + form.Visible + " Loaded=" + loaded + " Libraries=" + rows +
                " Tabs=" + tabs.TabPages.Count + " QueueRows=" + queue.Rows.Count + " EmailControl=" + email.Text);
            return form.Visible && loaded && rows >= 3 && tabs.TabPages.Count >= 5 && email.Enabled && queue.Rows.Count > 0 ? 0 : 1;
        }
        finally { form.Close(); form.Dispose(); }
    }

    private static TabControl FindTabs(Control parent)
    {
        foreach (Control child in parent.Controls)
        {
            var tab = child as TabControl;
            if (tab != null) return tab;
            var nested = FindTabs(child);
            if (nested != null) return nested;
        }
        return null;
    }
}
