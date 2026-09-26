// 为缺少 files/thumb 的 Flip PDF 电子书生成缩略图。
//
// 背景：Flip PDF 4.x 导出的电子书里，`files/mobile/1..N.jpg` 是页面图，
// `files/thumb/1..N.jpg` 是缩略图。有些导出（例如「怪兽的惊喜」「一起动起来！」）
// 的 thumb 目录是**空的** —— 此时播放器的加载动画永远不会结束（页面能看，但那个
// 图标一直转），手机/平板上的书签缩略图也永远截不到真正的封面。
//
// 这个工具用 JDK 自带的 ImageIO 把页面图缩成 thumb（无需 PIL/ImageMagick）。
//
// 用法:
//   javac -d /tmp/thumbs EbookThumbs.java
//   java -Djava.awt.headless=true -cp /tmp/thumbs EbookThumbs <电子书目录> [宽度] [质量]
//
// 例: java -Djava.awt.headless=true -cp /tmp/thumbs EbookThumbs /sdcard/ebooks/一起动起来！ 200 0.82
//
// 只会写入 <电子书目录>/files/thumb/；已存在的缩略图不会被动。

import java.awt.Graphics2D;
import java.awt.RenderingHints;
import java.awt.image.BufferedImage;
import java.io.File;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.Iterator;
import java.util.List;
import javax.imageio.IIOImage;
import javax.imageio.ImageIO;
import javax.imageio.ImageWriteParam;
import javax.imageio.ImageWriter;
import javax.imageio.stream.ImageOutputStream;

public final class EbookThumbs {

    public static void main(String[] args) throws Exception {
        if (args.length < 1) {
            System.err.println("用法: EbookThumbs <电子书目录> [宽度=200] [质量=0.82]");
            System.exit(2);
        }
        File book = new File(args[0]);
        int maxWidth = args.length > 1 ? Integer.parseInt(args[1]) : 200;
        float quality = args.length > 2 ? Float.parseFloat(args[2]) : 0.82f;

        File pages = new File(book, "files/mobile");
        File thumbs = new File(book, "files/thumb");
        if (!pages.isDirectory()) {
            System.err.println("找不到页面目录: " + pages);
            System.exit(1);
        }
        if (!thumbs.isDirectory() && !thumbs.mkdirs()) {
            System.err.println("无法创建: " + thumbs);
            System.exit(1);
        }

        List<File> images = new ArrayList<>();
        File[] listed = pages.listFiles();
        if (listed != null) {
            for (File file : listed) {
                String name = file.getName().toLowerCase();
                if (file.isFile() && (name.endsWith(".jpg") || name.endsWith(".jpeg")
                        || name.endsWith(".png"))) {
                    images.add(file);
                }
            }
        }
        // 1.jpg, 2.jpg, ... 10.jpg —— 按页码而不是字典序。
        images.sort(Comparator.comparingInt(EbookThumbs::pageNumber)
                .thenComparing(File::getName));

        int written = 0;
        for (File page : images) {
            File target = new File(thumbs, baseName(page) + ".jpg");
            if (target.exists() && target.length() > 0) {
                continue; // 已有的缩略图不动
            }
            BufferedImage source = ImageIO.read(page);
            if (source == null) {
                System.err.println("读不出图片，跳过: " + page);
                continue;
            }
            int width = Math.min(maxWidth, source.getWidth());
            int height = Math.max(1, (int) Math.round(source.getHeight() * (width / (double) source.getWidth())));
            BufferedImage scaled = new BufferedImage(width, height, BufferedImage.TYPE_INT_RGB);
            Graphics2D g = scaled.createGraphics();
            try {
                g.setRenderingHint(RenderingHints.KEY_INTERPOLATION,
                        RenderingHints.VALUE_INTERPOLATION_BILINEAR);
                g.setRenderingHint(RenderingHints.KEY_RENDERING, RenderingHints.VALUE_RENDER_QUALITY);
                g.drawImage(source, 0, 0, width, height, null);
            } finally {
                g.dispose();
            }
            writeJpeg(scaled, target, quality);
            written++;
        }
        System.out.println("完成：" + book.getName() + " 生成 " + written + " 个缩略图 → " + thumbs);
    }

    private static void writeJpeg(BufferedImage image, File target, float quality) throws Exception {
        Iterator<ImageWriter> writers = ImageIO.getImageWritersByFormatName("jpg");
        if (!writers.hasNext()) throw new IllegalStateException("没有 JPEG 编码器");
        ImageWriter writer = writers.next();
        try (ImageOutputStream out = ImageIO.createImageOutputStream(target)) {
            writer.setOutput(out);
            ImageWriteParam param = writer.getDefaultWriteParam();
            if (param.canWriteCompressed()) {
                param.setCompressionMode(ImageWriteParam.MODE_EXPLICIT);
                param.setCompressionQuality(quality);
            }
            writer.write(null, new IIOImage(image, null, null), param);
        } finally {
            writer.dispose();
        }
    }

    private static String baseName(File file) {
        String name = file.getName();
        int dot = name.lastIndexOf('.');
        return dot > 0 ? name.substring(0, dot) : name;
    }

    private static int pageNumber(File file) {
        String name = baseName(file);
        StringBuilder digits = new StringBuilder();
        for (int i = 0; i < name.length() && Character.isDigit(name.charAt(i)); i++) {
            digits.append(name.charAt(i));
        }
        try {
            return Integer.parseInt(digits.toString());
        } catch (NumberFormatException e) {
            return Integer.MAX_VALUE;
        }
    }
}
