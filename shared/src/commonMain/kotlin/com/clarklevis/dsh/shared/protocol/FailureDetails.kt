package com.clarklevis.dsh.shared.protocol

internal fun failureText(value: JsonValue?): String? {
    value?.stringValue?.takeIf { it.isNotBlank() }?.let { return it }
    val message = listOf("message", "reason", "code", "name")
        .firstNotNullOfOrNull { value?.get(it)?.stringValue?.takeIf(String::isNotBlank) } ?: return null
    val facts = listOfNotNull(
        value?.get("code")?.stringValue?.takeIf { it != message },
        value?.get("status")?.doubleValue?.toInt()?.let { "HTTP $it" }
    )
    return if (facts.isEmpty()) message else "$message (${facts.joinToString(" · ")})"
}
