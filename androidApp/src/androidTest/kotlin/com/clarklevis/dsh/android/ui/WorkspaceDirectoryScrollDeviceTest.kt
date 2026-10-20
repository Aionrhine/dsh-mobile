package com.clarklevis.dsh.android.ui

import android.graphics.Bitmap
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.layout.boundsInWindow
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollToIndex
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.swipeDown
import androidx.compose.ui.test.swipeUp
import androidx.test.platform.app.InstrumentationRegistry
import com.clarklevis.dsh.android.AndroidSharedStateHolder
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import java.util.Locale
import java.util.concurrent.CopyOnWriteArrayList
import java.io.File

class WorkspaceDirectoryScrollDeviceTest {
    @get:Rule val compose = createComposeRule()
    private lateinit var previousLocale: Locale

    @Before fun useChineseLabels() {
        previousLocale = Locale.getDefault()
        Locale.setDefault(Locale.SIMPLIFIED_CHINESE)
    }

    @After fun restoreLocale() { Locale.setDefault(previousLocale) }

    @Test
    fun upwardDragsAtEndOfDirectoryListKeepSheetAndFooterStill() {
        val positions = CopyOnWriteArrayList<Rect>()
        val holder = showDirectorySheet(onSheetPosition = { positions += it })
        try {
            val list = compose.onNodeWithTag("directory-browser-list")
            list.performScrollToIndex(60)
            val expandedSheet = positions.last()
            assertTrue("面板顶部应保留留白，不能撑满整个屏幕", expandedSheet.top > 0f)
            val footer = bounds("create-workspace")
            // 记录布局过程中每次位置和尺寸变化，不能只检查动画最终落点。
            positions.clear()
            repeat(3) {
                list.performTouchInput { swipeUp(durationMillis = 450) }
                compose.mainClock.advanceTimeBy(700)
                compose.waitForIdle()
                positions.toList().ifEmpty { listOf(expandedSheet) }.forEach { current ->
                    assertEquals("到达列表底部后，弹窗上边缘不能抖动", expandedSheet.top, current.top, 1f)
                    assertEquals("到达列表底部后，弹窗高度不能反复变化", expandedSheet.height, current.height, 1f)
                }
                assertEquals("创建工作区按钮应固定在底部", footer.top, bounds("create-workspace").top, 1f)
            }
            compose.onNodeWithTag("directory-row-/home/test/folder-59").assertIsDisplayed()
            val instrumentation = InstrumentationRegistry.getInstrumentation()
            val bitmap = instrumentation.uiAutomation.takeScreenshot()
            File(instrumentation.targetContext.cacheDir, "directory-scroll-stable.png").outputStream().use {
                bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)
            }
            bitmap.recycle()
            // 到底后仍能反向浏览，不能通过禁止列表滚动消除抖动。
            list.performTouchInput { swipeDown(durationMillis = 500) }
            list.performScrollToIndex(0)
            compose.onNodeWithText("返回上一级").assertIsDisplayed()
        } finally {
            compose.runOnIdle { holder.close() }
        }
    }

    @Test
    fun directorySheetStillSupportsDownwardDismissAndCancel() {
        var visible by mutableStateOf(true)
        val holder = showDirectorySheet(visible = { visible }, onDismiss = { visible = false })
        try {
            compose.onNodeWithTag("directory-browser-list").performTouchInput {
                swipeDown(startY = top + 24f, endY = bottom - 12f, durationMillis = 400)
            }
            compose.onNodeWithTag("directory-browser-sheet").assertDoesNotExist()
            compose.runOnIdle { visible = true }
            compose.onNodeWithText("取消").performClick()
            compose.onNodeWithTag("directory-browser-sheet").assertDoesNotExist()
        } finally { compose.runOnIdle { holder.close() } }
    }

    private fun showDirectorySheet(
        visible: () -> Boolean = { true }, onDismiss: () -> Unit = {},
        onSheetPosition: (Rect) -> Unit = {}
    ): AndroidSharedStateHolder {
        val holder = AndroidSharedStateHolder()
        compose.setContent {
            DshTheme {
                AdaptiveWindowHost {
                    Box(Modifier.fillMaxSize()) {
                        if (visible()) WorkspaceDirectoryBrowserSheet(holder, onDismiss,
                            Modifier.onGloballyPositioned { onSheetPosition(it.boundsInWindow()) })
                    }
                }
            }
        }
        compose.runOnIdle {
            val entries = (0..<60).joinToString(",") {
                """{"name":"folder-${it.toString().padStart(2, '0')}","path":"/home/test/folder-${it.toString().padStart(2, '0')}"}"""
            }
            holder.wirePayload = """{"kind":"directories","path":"/home/test","home":"/home/test","crumbs":[{"name":"home","path":"/home"},{"name":"test","path":"/home/test"}],"entries":[$entries]}"""
            holder.submitWirePayload()
        }
        compose.onNodeWithTag("directory-browser-list").assertIsDisplayed()
        return holder
    }

    private fun bounds(tag: String): Rect = compose.onNodeWithTag(tag).fetchSemanticsNode().boundsInRoot
}
