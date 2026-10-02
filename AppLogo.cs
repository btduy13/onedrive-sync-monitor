using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;

internal static class AppLogo
{
    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool DestroyIcon(IntPtr handle);

    public static Bitmap Render(int size)
    {
        var bitmap = new Bitmap(size, size);
        using (var graphics = Graphics.FromImage(bitmap))
        {
            graphics.SmoothingMode = SmoothingMode.AntiAlias;
            graphics.Clear(Color.Transparent);
            graphics.ScaleTransform(size / 64f, size / 64f);
            using (var path = RoundedRectangle(new RectangleF(2, 2, 60, 60), 14))
            using (var background = new LinearGradientBrush(new PointF(0, 0), new PointF(64, 64),
                Color.FromArgb(16, 64, 107), Color.FromArgb(24, 114, 165)))
                graphics.FillPath(background, path);

            // A white cloud above two directional sync arrows: readable even at tray size.
            using (var white = new SolidBrush(Color.White))
            {
                graphics.FillEllipse(white, 12, 25, 22, 19);
                graphics.FillEllipse(white, 23, 17, 24, 27);
                graphics.FillEllipse(white, 40, 26, 13, 17);
                graphics.FillRectangle(white, 18, 34, 29, 10);
            }
            using (var navy = new SolidBrush(Color.FromArgb(16, 64, 107)))
                graphics.FillRectangle(navy, 17, 40, 30, 5);
            using (var cyan = new Pen(Color.FromArgb(76, 230, 215), 4.2f))
            using (var amber = new Pen(Color.FromArgb(255, 200, 91), 4.2f))
            {
                cyan.StartCap = LineCap.Round; cyan.EndCap = LineCap.Round;
                amber.StartCap = LineCap.Round; amber.EndCap = LineCap.Round;
                graphics.DrawArc(cyan, 18, 38, 28, 20, 205, 135);
                graphics.DrawLines(cyan, new[] { new PointF(46, 42), new PointF(46, 50), new PointF(39, 47) });
                graphics.DrawArc(amber, 18, 38, 28, 20, 25, 135);
                graphics.DrawLines(amber, new[] { new PointF(18, 54), new PointF(18, 46), new PointF(25, 49) });
            }
        }
        return bitmap;
    }

    public static Icon CreateIcon(int size)
    {
        using (var bitmap = Render(size))
        {
            var handle = bitmap.GetHicon();
            try { using (var icon = Icon.FromHandle(handle)) return (Icon)icon.Clone(); }
            finally { DestroyIcon(handle); }
        }
    }

    private static GraphicsPath RoundedRectangle(RectangleF rectangle, float radius)
    {
        var path = new GraphicsPath();
        float diameter = radius * 2;
        path.AddArc(rectangle.Left, rectangle.Top, diameter, diameter, 180, 90);
        path.AddArc(rectangle.Right - diameter, rectangle.Top, diameter, diameter, 270, 90);
        path.AddArc(rectangle.Right - diameter, rectangle.Bottom - diameter, diameter, diameter, 0, 90);
        path.AddArc(rectangle.Left, rectangle.Bottom - diameter, diameter, diameter, 90, 90);
        path.CloseFigure();
        return path;
    }
}
