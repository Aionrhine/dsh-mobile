package com.clarklevis.dsh.android.localization

import com.clarklevis.dsh.android.MobilePluginBundle
import com.clarklevis.dsh.android.ui.AppLanguage
import com.clarklevis.dsh.android.ui.InterfaceStyle
import com.clarklevis.dsh.android.ui.ScheduledTaskStatusFilter
import com.clarklevis.dsh.android.ui.agentPresetDisplayName
import com.clarklevis.dsh.android.ui.appLocale
import com.clarklevis.dsh.android.ui.localizedToolActivitySummary
import com.clarklevis.dsh.android.ui.relativeTime
import com.clarklevis.dsh.shared.projection.ToolActivitySummaryFormatter
import com.clarklevis.dsh.shared.protocol.GatewayWireDecoder
import java.util.Locale
import java.util.TimeZone
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test

class AndroidStringsTest {
    @get:Rule val locale = LocaleTestRule(Locale.ENGLISH)

    @Test
    fun screenshotChromeAndComposerAreFullyEnglish() {
        val labels = listOf(
            "已连接Deepseek Harness预览版", "新建会话", "最近会话", "搜索会话内容", "已连接",
            "描述你想要构建的内容", "输入内容或按住说话"
        ).map { appText(it) }
        assertEquals(listOf(
            "Connected to DeepSeek Harness Preview", "New session", "Recent sessions",
            "Search session content", "Connected", "Describe what you want to build",
            "Type a message or hold to speak"
        ), labels)
    }

    @Test
    fun catalogHasEnglishForEveryEntryWithMatchingArguments() {
        val argument = Regex("%(\\d+)\\\$s")
        AndroidStrings.english.forEach { (source, english) ->
            assertTrue("Empty translation: $source", english.isNotBlank())
            assertFalse("Untranslated copy: $source", english.any { it in '\u4e00'..'\u9fff' })
            assertEquals(
                "Translation arguments: $source",
                argument.findAll(source).map { it.groupValues[1] }.toSet(),
                argument.findAll(english).map { it.groupValues[1] }.toSet()
            )
        }
    }

    @Test
    fun formattedUserValuesArePreservedLiterally() {
        val filename = "进度 100% \$1.txt"
        assertEquals("Downloading $filename", appText("正在下载 %1\$s", filename))
        assertEquals("Downloading · 50%", appText("正在下载 · %1\$s%", 50))
        assertEquals("Page 2", appText("第 %1\$s 页", 2))
        assertEquals("只属于用户的中文标题", appText("只属于用户的中文标题"))
    }

    @Test
    fun relativeTimeUsesEnglishAndSingularCounts() {
        val now = 1_800_000_000_000L
        val zone = TimeZone.getTimeZone("UTC")
        assertEquals("Just now", relativeTime(now / 1_000.0, now, zone))
        assertEquals("1 minute ago", relativeTime((now - 60_000) / 1_000.0, now, zone))
        assertEquals("2 minutes ago", relativeTime((now - 120_000) / 1_000.0, now, zone))
        assertEquals("Yesterday", relativeTime((now - 86_400_000) / 1_000.0, now, zone))
        assertEquals("3 days ago", relativeTime((now - 259_200_000) / 1_000.0, now, zone))
    }

    @Test
    fun localePreferenceAndEnumLabelsFollowTheActiveLanguage() {
        assertEquals(Locale.ENGLISH, appLocale(AppLanguage.ENGLISH, Locale.CHINA))
        assertEquals(Locale.SIMPLIFIED_CHINESE, appLocale(AppLanguage.SIMPLIFIED_CHINESE, Locale.US))
        assertEquals(Locale.UK, appLocale(AppLanguage.SYSTEM, Locale.UK))
        assertEquals(Locale.CHINA, appLocale(AppLanguage.SYSTEM, Locale.CHINA))
        assertEquals(Locale.ENGLISH, appLocale(AppLanguage.SYSTEM, Locale.JAPAN))
        assertEquals("Light", InterfaceStyle.LIGHT.title)
        assertEquals("Active", ScheduledTaskStatusFilter.ACTIVE.title)
        assertEquals("Standard mode", agentPresetDisplayName("standard"))
        assertEquals("团队预设", agentPresetDisplayName("team", "团队预设"))
        Locale.setDefault(Locale.SIMPLIFIED_CHINESE)
        assertEquals("浅色", InterfaceStyle.LIGHT.title)
        assertEquals("已开启", ScheduledTaskStatusFilter.ACTIVE.title)
        assertEquals("新建会话", appText("新建会话"))
        assertEquals("正在下载 · 50%", appText("正在下载 · %1\$s%", 50))
    }

    @Test
    fun retainedPluginMetadataFollowsLocaleAndSkipsBlankTranslations() {
        val frame = GatewayWireDecoder.decode("""
            {"kind":"plugin-catalog","bundles":[
              {"name":"plugin","meta":{"title":{"zh":"自动化任务","en":"Automation tasks"}}},
              {"name":"fallback","meta":{"title":{"en":" ","zh":"仅中文"}}}
            ]}
        """.trimIndent())
        val bundle = MobilePluginBundle(frame.bundles!![0])
        assertEquals("Automation tasks", bundle.title)
        assertEquals("仅中文", MobilePluginBundle(frame.bundles!![1]).title)
        Locale.setDefault(Locale.SIMPLIFIED_CHINESE)
        assertEquals("自动化任务", bundle.title)
    }

    @Test
    fun toolSummaryTranslatesLabelsAndCountsWhilePreservingPaths() {
        val summary = localizedToolActivitySummary(ToolActivitySummaryFormatter.summarize(
            "write_file", """{"path":"项目/中文.kt","content":"one\ntwo"}"""
        ))
        assertEquals("Write", summary.label)
        assertEquals("2 lines", summary.annotation)
        assertEquals("项目/中文.kt", summary.detail)
    }
}
