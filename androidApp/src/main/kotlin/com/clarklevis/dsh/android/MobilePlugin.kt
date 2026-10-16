package com.clarklevis.dsh.android

import com.clarklevis.dsh.android.localization.appText
import com.clarklevis.dsh.shared.protocol.JsonValue
import java.util.Locale

private val hiddenProfileBundles = setOf(
    "@deepseek-ai/dsh-base", "@deepseek-ai/dsh-web-app", "@deepseek-ai/dsh-headless",
    "@deepseek-ai/dsh-sdk-app", "@deepseek-ai/dsh-acp-app", "@deepseek-ai/dsh-sdk-minimal"
)

data class MobilePluginBundle(val raw: JsonValue) {
    val name: String = raw["name"]?.stringValue.orEmpty()
    val version: String? = raw["version"]?.stringValue
    val enabled: Boolean = raw["enabled"]?.booleanValue == true
    val installed: Boolean = raw["installed"]?.booleanValue == true
    val optional: Boolean = raw["optional"]?.booleanValue == true
    val experimental: Boolean = raw["experimental"]?.booleanValue == true
    val removable: Boolean = raw["removable"]?.booleanValue == true
    val readOnlyReason: String? = raw["readOnlyReason"]?.stringValue
    val error: String? = raw["error"]?.get("diagnostic")?.stringValue
        ?: raw["error"]?.get("code")?.stringValue
    val title: String get() = localized(raw["meta"]?.get("title")) ?: name
    val description: String get() = localized(raw["meta"]?.get("description"))
        ?: raw["description"]?.stringValue.orEmpty()
    val icon: String? = raw["meta"]?.get("icon")?.stringValue
    val rows: List<JsonValue> = raw["rows"]?.arrayValue.orEmpty()
    val visible: Boolean get() = name !in hiddenProfileBundles && (installed || optional || error != null)
    val isOfficial: Boolean get() = optional && !installed
}

data class MobilePluginEntry(val raw: JsonValue) {
    val entryId: String = raw["entryId"]?.stringValue ?: raw["id"]?.stringValue.orEmpty()
    val name: String get() = localized(raw["meta"]?.get("title"))
        ?: raw["name"]?.stringValue ?: entryId
    val description: String get() = localized(raw["meta"]?.get("description"))
        ?: raw["description"]?.stringValue.orEmpty()
    val enabled: Boolean = raw["enabled"]?.booleanValue == true
    val readOnlyReason: String? = raw["readOnlyReason"]?.stringValue
    val icon: String? = raw["meta"]?.get("icon")?.stringValue
    val fiberPhase: String? = raw["fiberPhase"]?.stringValue
}

data class MobilePluginRow(val raw: JsonValue, val live: MobilePluginEntry?) {
    val rowId: String = raw["rowId"]?.stringValue.orEmpty()
    val entryId: String? = raw["entryId"]?.stringValue
    val moduleName: String = raw["moduleName"]?.stringValue.orEmpty()
    val name: String get() = localized(raw["meta"]?.get("title")) ?: live?.name ?: rowId
    val description: String get() = localized(raw["meta"]?.get("description"))
        ?: live?.description.orEmpty()
    val icon: String? = raw["meta"]?.get("icon")?.stringValue ?: live?.icon
    val enabled: Boolean = live?.enabled == true
    val phase: String? = live?.fiberPhase
    val readOnlyReason: String? = live?.readOnlyReason
    val statusText: String get() = when {
        !enabled -> appText("已停用")
        phase == "active" -> appText("运行中")
        phase == "failed" -> appText("运行失败")
        phase == "loading" -> appText("加载中")
        phase == "unloading" -> appText("卸载中")
        phase == "pending" -> appText("待启动")
        else -> appText("空闲")
    }
}

data class MobileOfficialPlugin(val raw: JsonValue) {
    val id: String = raw["id"]?.stringValue.orEmpty()
    val namespaces: List<String> = raw["namespaces"]?.arrayValue.orEmpty().mapNotNull { it.stringValue }
    val title: String get() = when (id) {
        "shell" -> appText("终端")
        "agent-loop" -> appText("Agent 循环")
        "subagent" -> appText("子智能体")
        "web-search" -> appText("网页搜索")
        else -> id
    }
    val description: String get() = when (id) {
        "shell" -> appText("限制每条命令最多能跑多久、最多输出多少内容。")
        "agent-loop" -> appText("控制 Agent 派发工具调用的方式。")
        "subagent" -> appText("设置子智能体的递归层级、数量和模型。")
        "web-search" -> appText("设置 DeepSeek 的搜索提供方。")
        else -> ""
    }
}

data class MobilePluginCatalog(
    val managementAvailable: Boolean,
    val settingsWritable: Boolean,
    val bundles: List<MobilePluginBundle>,
    val plugins: List<MobilePluginEntry>,
    val officialItems: List<MobileOfficialPlugin>
) {
    val officialBundles: List<MobilePluginBundle> get() = bundles
        .filter { it.visible && it.isOfficial }
        .sortedWith(compareBy<MobilePluginBundle> { it.name.shortPluginName() }.thenBy { it.name })
    val installedBundles: List<MobilePluginBundle> get() = bundles
        .filter { it.visible && !it.isOfficial }
        .sortedWith(compareBy<MobilePluginBundle> { it.name.shortPluginName() }.thenBy { it.name })
}

private fun String.shortPluginName(): String {
    val unscoped = if (startsWith('@')) substringAfter('/') else this
    return when {
        unscoped.startsWith("dsh-host-") -> unscoped.removePrefix("dsh-host-")
        unscoped.startsWith("dsh-client-") -> unscoped.removePrefix("dsh-client-")
        else -> unscoped.removePrefix("dsh-")
    }
}

private fun localized(value: JsonValue?): String? {
    value?.stringValue?.takeIf { it.isNotBlank() }?.let { return it }
    val translations = value?.objectValue ?: return null
    val locale = Locale.getDefault()
    val preferred = if (locale.language == "zh") {
        listOf(locale.toLanguageTag(), "zh-Hans", "zh-CN", "zh", "en")
    } else {
        listOf(locale.toLanguageTag(), "en", "zh", "zh-Hans", "zh-CN")
    }
    return (preferred.mapNotNull { translations[it] } + translations.values)
        .firstNotNullOfOrNull { it.stringValue?.takeIf(String::isNotBlank) }
}
