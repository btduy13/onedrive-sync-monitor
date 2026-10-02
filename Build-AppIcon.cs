using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;

internal static class BuildAppIcon
{
    private static int Main(string[] args)
    {
        if (args.Length != 1) return 2;
        int[] sizes = { 16, 32, 48, 256 };
        var images = new byte[sizes.Length][];
        for (int i = 0; i < sizes.Length; i++)
        {
            using (var bitmap = AppLogo.Render(sizes[i]))
            using (var memory = new MemoryStream())
            {
                bitmap.Save(memory, ImageFormat.Png);
                images[i] = memory.ToArray();
            }
        }
        using (var output = File.Create(args[0]))
        using (var writer = new BinaryWriter(output))
        {
            writer.Write((ushort)0); writer.Write((ushort)1); writer.Write((ushort)sizes.Length);
            int offset = 6 + 16 * sizes.Length;
            for (int i = 0; i < sizes.Length; i++)
            {
                writer.Write((byte)(sizes[i] == 256 ? 0 : sizes[i]));
                writer.Write((byte)(sizes[i] == 256 ? 0 : sizes[i]));
                writer.Write((byte)0); writer.Write((byte)0);
                writer.Write((ushort)1); writer.Write((ushort)32);
                writer.Write(images[i].Length); writer.Write(offset);
                offset += images[i].Length;
            }
            foreach (var bytes in images) writer.Write(bytes);
        }
        return 0;
    }
}
