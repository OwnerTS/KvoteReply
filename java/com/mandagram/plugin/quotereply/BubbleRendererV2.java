package com.mandagram.plugin.quotereply;

import androidx.compose.ui.ImageComposeScene;
import androidx.compose.ui.unit.DensityKt;
import androidx.compose.runtime.Composer;
import com.mandagram.models.MessageItem;
import com.mandagram.ui.chat.MessageBubbleKt;
import com.mandagram.ui.theme.ThemeKt;
import com.mandagram.utils.AppPaths;
import kotlin.Unit;
import kotlin.jvm.functions.Function2;
import kotlin.coroutines.EmptyCoroutineContext;
import org.jetbrains.skia.*;
import java.io.File;
import java.io.FileOutputStream;

public class BubbleRendererV2 {

    public static byte[] renderMessageToPng(MessageItem msg) {
        if (msg == null) return null;
        boolean isOutgoing = msg.isOutgoing();
        boolean isChannel = msg.isChannelPost();
        boolean isGroup = !isOutgoing && !isChannel;

        Function2<Composer, Integer, Unit> inner = new Function2<Composer, Integer, Unit>() {
            @Override
            public Unit invoke(Composer composer, Integer changed) {
                MessageBubbleKt.MessageBubble(
                    msg, isGroup, true, true, isChannel, 0L,
                    null, null, null, null, null, null, null, null, null,
                    composer, 54, 0, 0x7FF0
                );
                return Unit.INSTANCE;
            }
        };

        Function2<Composer, Integer, Unit> themed = new Function2<Composer, Integer, Unit>() {
            @Override
            public Unit invoke(Composer composer, Integer changed) {
                ThemeKt.MandaGramTheme(inner, composer, 0);
                return Unit.INSTANCE;
            }
        };

        int sceneW = 650;
        int sceneH = 1500;
        ImageComposeScene scene = new ImageComposeScene(
            sceneW, sceneH, DensityKt.Density(1.0f, 1.0f), EmptyCoroutineContext.INSTANCE, themed
        );
        try {
            Image fullImg = scene.render(0L);
            if (fullImg == null) return null;

            Bitmap bmp = Bitmap.Companion.makeFromImage(fullImg);
            if (bmp == null) {
                Data data = fullImg.encodeToData(EncodedImageFormat.PNG, 100);
                return data != null ? data.getBytes() : null;
            }

            int w = bmp.getWidth();
            int h = bmp.getHeight();
            int minX = w, maxX = 0, minY = h, maxY = 0;

            for (int y = 0; y < h; y++) {
                for (int x = 0; x < w; x++) {
                    int c = bmp.getColor(x, y);
                    int a = (c >> 24) & 0xFF;
                    if (a > 0) {
                        if (x < minX) minX = x;
                        if (x > maxX) maxX = x;
                        if (y < minY) minY = y;
                        if (y > maxY) maxY = y;
                    }
                }
            }

            if (minX <= maxX && minY <= maxY) {
                int pad = 6;
                minX = Math.max(0, minX - pad);
                minY = Math.max(0, minY - pad);
                maxX = Math.min(w, maxX + 1 + pad);
                maxY = Math.min(h, maxY + 1 + pad);

                int cropW = maxX - minX;
                int cropH = maxY - minY;

                Surface surface = Surface.Companion.makeRasterN32Premul(cropW, cropH);
                if (surface != null) {
                    surface.getCanvas().drawImageRect(
                        fullImg,
                        Rect.Companion.makeLTRB(minX, minY, maxX, maxY),
                        Rect.Companion.makeWH(cropW, cropH)
                    );
                    Image cropped = surface.makeImageSnapshot();
                    Data data = cropped.encodeToData(EncodedImageFormat.PNG, 100);
                    return data != null ? data.getBytes() : null;
                }
            }

            Data data = fullImg.encodeToData(EncodedImageFormat.PNG, 100);
            return data != null ? data.getBytes() : null;
        } catch (Throwable t) {
            t.printStackTrace();
            return null;
        } finally {
            scene.close();
        }
    }

    public static String renderMessageToFile(MessageItem msg, String preferredPath) {
        try {
            byte[] bytes = renderMessageToPng(msg);
            if (bytes == null || bytes.length == 0) return null;

            File targetFile;
            if (preferredPath != null && !preferredPath.isEmpty()) {
                targetFile = new File(preferredPath);
                File parent = targetFile.getParentFile();
                if (parent != null) parent.mkdirs();
            } else {
                File cacheDir = new File(AppPaths.INSTANCE.getDataDir(), "cache");
                cacheDir.mkdirs();
                targetFile = new File(cacheDir, "quote_reply_" + System.currentTimeMillis() + ".png");
            }

            try (FileOutputStream fos = new FileOutputStream(targetFile)) {
                fos.write(bytes);
            }
            return targetFile.getAbsolutePath();
        } catch (Throwable t) {
            t.printStackTrace();
            return null;
        }
    }
}
