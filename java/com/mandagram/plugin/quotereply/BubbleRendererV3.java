package com.mandagram.plugin.quotereply;

import androidx.compose.ui.ImageComposeScene;
import androidx.compose.ui.unit.DensityKt;
import androidx.compose.runtime.Composer;
import com.mandagram.models.MessageItem;
import com.mandagram.ui.chat.MessageBubbleKt;
import com.mandagram.ui.theme.ThemeKt;
import kotlin.Unit;
import kotlin.jvm.functions.Function2;
import kotlin.coroutines.EmptyCoroutineContext;
import org.jetbrains.skia.*;

public class BubbleRendererV3 implements Function2<Composer, Integer, Unit> {

    private static final BubbleRendererV3 INSTANCE = new BubbleRendererV3();

    private MessageItem currentMsg;
    private boolean isGroup;
    private boolean isChannel;
    private int currentPass = 0;

    @Override
    public Unit invoke(Composer composer, Integer changed) {
        if (currentPass == 0) {
            currentPass = 1;
            try {
                ThemeKt.MandaGramTheme(this, composer, 0);
            } finally {
                currentPass = 0;
            }
        } else {
            MessageBubbleKt.MessageBubble(
                currentMsg, isGroup, true, true, isChannel, 0L,
                null, null, null, null, null, null, null, null, null,
                composer, 54, 0, 0x7FC0
            );
        }
        return Unit.INSTANCE;
    }

    public static byte[] renderMessageToPng(MessageItem msg, int chatBg) {
        if (msg == null) return null;
        synchronized (INSTANCE) {
            INSTANCE.currentMsg = msg;
            boolean isOutgoing = msg.isOutgoing();
            boolean isChannel = msg.isChannelPost();
            INSTANCE.isGroup = !isOutgoing && !isChannel;
            INSTANCE.isChannel = isChannel;
            INSTANCE.currentPass = 0;

            int sceneW = 650;
            int sceneH = 1500;
            ImageComposeScene scene = new ImageComposeScene(
                sceneW, sceneH, DensityKt.Density(1.0f, 1.0f), EmptyCoroutineContext.INSTANCE, INSTANCE
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
                Pixmap pixmap = bmp.peekPixels();
                byte[] pixels = (pixmap != null && pixmap.getBuffer() != null) ? pixmap.getBuffer().getBytes() : null;

                int minX = w, maxX = 0, minY = h, maxY = -1;

                if (pixels != null && pixels.length >= w * h * 4) {
                    int rowBytes = pixmap.getRowBytes();

                    // Find minY
                    for (int y = 0; y < h; y++) {
                        int rowOffset = y * rowBytes;
                        boolean hasPixel = false;
                        for (int x = 0; x < w; x++) {
                            if ((pixels[rowOffset + x * 4 + 3] & 0xFF) > 0) {
                                minY = y;
                                hasPixel = true;
                                break;
                            }
                        }
                        if (hasPixel) break;
                    }

                    // Find maxY
                    for (int y = h - 1; y >= minY; y--) {
                        int rowOffset = y * rowBytes;
                        boolean hasPixel = false;
                        for (int x = 0; x < w; x++) {
                            if ((pixels[rowOffset + x * 4 + 3] & 0xFF) > 0) {
                                maxY = y;
                                hasPixel = true;
                                break;
                            }
                        }
                        if (hasPixel) break;
                    }

                    // Find minX and maxX within [minY, maxY]
                    if (maxY >= minY) {
                        for (int y = minY; y <= maxY; y++) {
                            int rowOffset = y * rowBytes;
                            for (int x = 0; x < minX; x++) {
                                if ((pixels[rowOffset + x * 4 + 3] & 0xFF) > 0) {
                                    minX = x;
                                    break;
                                }
                            }
                            for (int x = w - 1; x > maxX; x--) {
                                if ((pixels[rowOffset + x * 4 + 3] & 0xFF) > 0) {
                                    maxX = x;
                                    break;
                                }
                            }
                        }
                    }
                } else {
                    for (int y = 0; y < h; y += 2) {
                        for (int x = 0; x < w; x += 2) {
                            int c = bmp.getColor(x, y);
                            if (((c >> 24) & 0xFF) > 0) {
                                if (x < minX) minX = x;
                                if (x > maxX) maxX = x;
                                if (y < minY) minY = y;
                                if (y > maxY) maxY = y;
                            }
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
                        Canvas canvas = surface.getCanvas();
                        canvas.clear(chatBg);
                        canvas.drawImageRect(
                            fullImg,
                            Rect.Companion.makeLTRB(minX, minY, maxX, maxY),
                            Rect.Companion.makeWH(cropW, cropH)
                        );
                        Image cropped = surface.makeImageSnapshot();
                        Data data = cropped.encodeToData(EncodedImageFormat.PNG, 100);
                        return data != null ? data.getBytes() : null;
                    }
                }

                Surface surface = Surface.Companion.makeRasterN32Premul(w, h);
                if (surface != null) {
                    Canvas canvas = surface.getCanvas();
                    canvas.clear(chatBg);
                    canvas.drawImage(fullImg, 0, 0);
                    Image bgImg = surface.makeImageSnapshot();
                    Data data = bgImg.encodeToData(EncodedImageFormat.PNG, 100);
                    return data != null ? data.getBytes() : null;
                }

                Data data = fullImg.encodeToData(EncodedImageFormat.PNG, 100);
                return data != null ? data.getBytes() : null;
            } finally {
                scene.close();
                INSTANCE.currentMsg = null;
            }
        }
    }
}
