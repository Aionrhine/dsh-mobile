package com.clarklevis.dsh.android.ui

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.text.Spanned
import android.text.style.ClickableSpan
import androidx.compose.runtime.mutableStateOf
import com.clarklevis.dsh.shared.protocol.PresentedFile
import android.text.TextPaint
import android.view.View
import android.view.ViewGroup
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.platform.LocalView
import io.noties.markwon.ext.tables.TableRowSpan
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class DshMarkdownTextDeviceTest {
    @get:Rule
    val compose = createComposeRule()

    @Test
    fun fileLinksAndKnownCodeUseCurrentCallbackWhileAmbiguousCodeStaysPlain() {
        var rootView: View? = null
        val source = mutableStateOf("s1")
        val opened = mutableListOf<String>()
        var originalText: CharSequence? = null
        val markdown = "[正文](<build/旅游%20攻略.pdf#L24>) `tutorial.pdf` `report.pdf` `unknown.pdf` [网页](https://example.com)"
        compose.setContent {
            rootView = LocalView.current
            val session = source.value
            DshTheme {
                DshLazyMarkdownText(markdown, knownFiles = listOf(
                    PresentedFile("build/tutorial.pdf"), PresentedFile("a/report.pdf"), PresentedFile("b/report.pdf")
                ), onOpenFile = { opened += "$session:$it" })
            }
        }
        fun clickFileReferences() {
            val view = requireNotNull(rootView?.findMarkdownTextView())
            val text = view.text as Spanned
            val spans = text.getSpans(0, text.length, ClickableSpan::class.java)
            val labels = spans.map { text.subSequence(text.getSpanStart(it), text.getSpanEnd(it)).toString() }
            assertEquals(setOf("正文", "tutorial.pdf", "网页"), labels.toSet())
            spans.filterIndexed { index, _ -> labels[index] != "网页" }.forEach { it.onClick(view) }
        }
        compose.runOnIdle {
            clickFileReferences()
            originalText = requireNotNull(rootView?.findMarkdownTextView()).text
            source.value = "s2"
        }
        compose.waitForIdle()
        compose.runOnIdle {
            assertSame("只改变会话回调不能重新设置正文和触发测量", originalText, rootView?.findMarkdownTextView()?.text)
            clickFileReferences()
        }
        assertEquals(listOf("s1:build/旅游 攻略.pdf", "s1:build/tutorial.pdf", "s2:build/旅游 攻略.pdf", "s2:build/tutorial.pdf"), opened)
    }

    @Test
    fun knownFileChangesAndCallbackRemovalRebindOnlyAffectedLinks() {
        var rootView: View? = null
        val files = mutableStateOf(listOf(PresentedFile("a/report.pdf")))
        val enabled = mutableStateOf(true)
        val opened = mutableListOf<String>()
        compose.setContent {
            rootView = LocalView.current
            DshTheme {
                DshLazyMarkdownText(
                    "请看 `report.pdf`",
                    knownFiles = files.value,
                    onOpenFile = if (enabled.value) ({ path -> opened += path }) else null
                )
            }
        }
        fun clickSingleLink() {
            val view = requireNotNull(rootView?.findMarkdownTextView())
            val text = view.text as Spanned
            text.getSpans(0, text.length, ClickableSpan::class.java).single().onClick(view)
        }
        compose.runOnIdle {
            clickSingleLink()
            files.value = listOf(PresentedFile("b/report.pdf"))
        }
        compose.waitForIdle()
        compose.runOnIdle {
            clickSingleLink()
            enabled.value = false
        }
        compose.waitForIdle()
        compose.runOnIdle {
            val text = requireNotNull(rootView?.findMarkdownTextView()).text as Spanned
            assertTrue(text.getSpans(0, text.length, ClickableSpan::class.java).isEmpty())
            enabled.value = true
        }
        compose.waitForIdle()
        compose.runOnIdle { clickSingleLink() }
        assertEquals(listOf("a/report.pdf", "b/report.pdf", "b/report.pdf"), opened)
    }

    @Test
    fun gfmTableIsRenderedAsTableSpans() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val markwon = buildDshMarkwon(context, testPalette())
        val markdown = """
            | 优先级 | 主文案 | 感觉 |
            | :--- | :--- | :---: |
            | ⭐ 推荐 | **平安喜乐** | 温暖 |
            | 备选 | ~~旧文案~~ | 克制 |
        """.trimIndent()

        val rendered = markwon.toMarkdown(markdown)
        val tableRows = rendered.getSpans(
            0,
            rendered.length,
            TableRowSpan::class.java
        )

        assertTrue("GFM 表格应生成 TableRowSpan", tableRows.isNotEmpty())
        assertFalse("表格分隔符不应作为普通正文显示", rendered.toString().contains(":---"))
    }

    @Test
    fun historyTablesImmediatelyAfterBoldLabelsRenderAfterLazySplitting() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val markwon = buildDshMarkwon(context, testPalette())
        val markdown = """
            如下（都是实测值，非目测）：

            ## 整体：深灰黑单色调 + 一个蓝色点缀

            **背景与容器**
            | 用途 | 色值 | 占比 |
            |---|---|---|
            | 页面背景（主色，近纯黑带一点冷灰） | `#151517` | 约 67% |
            | 输入卡片背景 | `#2C2C2E` | 约 25% |
            | 卡片内高亮/层次（略微偏离） | `#2D2C2F` / `#2B2C2F` | 约 3% |
            | 全图平均色 | `#1F1F22` | — |
            **文字与图标**
            | 用途 | 色值 |
            |---|---|
            | 主标题「探索未至之境」、工作区名「测试 2」 | `#FFFFFF` 纯白 |
        """.trimIndent()

        val rendered = splitMarkdownForLazyLayout(markdown).map(markwon::toMarkdown)
        val rows = rendered.sumOf {
            it.getSpans(0, it.length, TableRowSpan::class.java).size
        }
        assertEquals("两个历史表格都应渲染，包含表头共七行", 7, rows)
        assertTrue(rendered.joinToString("\n").contains("背景与容器"))
        assertTrue(rendered.joinToString("\n").contains("文字与图标"))
        assertFalse(rendered.joinToString("\n").contains("|---|"))
    }

    @Test
    fun longStreamingAndFinalMarkdownBothKeepTheDocumentTail() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val paragraphs = List(80) { index ->
            "第${index + 1}段：${"这是一段用于验证安卓长文本不会中断的内容。".repeat(8)}"
        }
        val streamingText = paragraphs.joinToString("\n\n")
        var rootView: View? = null
        compose.setContent {
            rootView = LocalView.current
            DshTheme {
                DshStreamingAwareMarkdownText(
                    markdown = streamingText,
                    isStreaming = true
                )
            }
        }
        compose.waitForIdle()
        // Markdown 使用 AndroidView 内的 TextView，正文不在 Compose 的 Text 语义节点中。
        compose.runOnIdle {
            val textView = requireNotNull(rootView?.findMarkdownTextView())
            assertTrue(textView.isShown)
            assertTrue(textView.text.contains(paragraphs.first()))
            assertTrue(textView.text.contains(paragraphs.last()))
            val layout = requireNotNull(textView.layout)
            assertEquals(textView.text.length, layout.getLineEnd(layout.lineCount - 1))
        }

        val markwon = buildDshMarkwon(
            context,
            testPalette()
        )
        val renderedFinal = markwon.toMarkdown(streamingText).toString()
        assertTrue(renderedFinal.contains(paragraphs.first()))
        assertTrue(renderedFinal.contains(paragraphs.last()))
    }

    @Test
    fun inlineCodeUsesRoundedBackgroundAndStillWrapsAcrossLines() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val palette = testPalette()
        val markwon = buildDshMarkwon(context, palette)
        val rendered = markwon.toMarkdown("前缀 `inline-code` 后缀")
        val span = rendered.getSpans(
            0,
            rendered.length,
            DshInlineCodeSpan::class.java
        ).single()
        assertEquals(palette.inlineCodeCornerRadiusPx, span.cornerRadiusPx, 0f)

        val textView = DshMarkdownTextView(context).apply {
            layoutParams = ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT,
                ViewGroup.LayoutParams.WRAP_CONTENT
            )
            includeFontPadding = false
            setPadding(0, 0, 0, 0)
            textSize = 20f
            text = rendered
        }
        textView.measure(
            View.MeasureSpec.makeMeasureSpec(600, View.MeasureSpec.EXACTLY),
            View.MeasureSpec.makeMeasureSpec(0, View.MeasureSpec.UNSPECIFIED)
        )
        textView.layout(0, 0, textView.measuredWidth, textView.measuredHeight)
        val bitmap = Bitmap.createBitmap(
            textView.measuredWidth,
            textView.measuredHeight,
            Bitmap.Config.ARGB_8888
        )
        textView.draw(Canvas(bitmap))

        val spanStart = rendered.getSpanStart(span)
        val spanEnd = rendered.getSpanEnd(span)
        val layout = requireNotNull(textView.layout)
        val codePaint = TextPaint(textView.paint).also(span::updateDrawState)
        val baseline = layout.getLineBaseline(0).toFloat()
        val top = (baseline + codePaint.fontMetrics.ascent - span.verticalPaddingPx)
            .coerceAtLeast(layout.getLineTop(0).toFloat())
        val left = (layout.getPrimaryHorizontal(spanStart) - span.horizontalPaddingPx)
            .coerceAtLeast(0f)
        val right = (layout.getPrimaryHorizontal(spanEnd) + span.horizontalPaddingPx)
            .coerceAtMost(layout.width.toFloat())
        val cornerAlpha = Color.alpha(
            bitmap.getPixel(left.toInt(), top.toInt())
        )
        val topCenterAlpha = Color.alpha(
            bitmap.getPixel(((left + right) / 2f).toInt(), (top + 1f).toInt())
        )
        assertTrue("圆角外侧像素应保持透明", cornerAlpha < 128)
        assertTrue("圆角顶部中央应绘制背景", topCenterAlpha > 128)

        val longRendered = markwon.toMarkdown(
            "命令 `rm /Users/lichaofan/__dsh_approval_demo__.txt` 结束"
        )
        val longSpan = longRendered.getSpans(
            0,
            longRendered.length,
            DshInlineCodeSpan::class.java
        ).single()
        textView.text = longRendered
        textView.measure(
            View.MeasureSpec.makeMeasureSpec(240, View.MeasureSpec.EXACTLY),
            View.MeasureSpec.makeMeasureSpec(0, View.MeasureSpec.UNSPECIFIED)
        )
        textView.layout(0, 0, textView.measuredWidth, textView.measuredHeight)
        assertTrue(
            "长行内代码必须保持可换行",
            textView.layout.getLineForOffset(longRendered.getSpanStart(longSpan)) <
                textView.layout.getLineForOffset(longRendered.getSpanEnd(longSpan) - 1)
        )
    }

    private fun View.findMarkdownTextView(): DshMarkdownTextView? {
        if (this is DshMarkdownTextView) return this
        if (this is ViewGroup) {
            for (index in 0 until childCount) {
                getChildAt(index).findMarkdownTextView()?.let { return it }
            }
        }
        return null
    }

    private fun testPalette() = DshMarkdownPalette(
        textColor = 0xFF10131A.toInt(),
        linkColor = 0xFF1478F2.toInt(),
        tableBorderColor = 0x3310131A,
        tableHeaderColor = 0x1410131A,
        tableOddRowColor = 0x0910131A,
        taskOutlineColor = 0x7310131A,
        tableBorderWidthPx = 1,
        tableCellPaddingPx = 8,
        inlineCodeBackgroundColor = 0xFFCBD5E1.toInt(),
        inlineCodeCornerRadiusPx = 10f,
        inlineCodeHorizontalPaddingPx = 8f,
        inlineCodeVerticalPaddingPx = 2f
    )
}
