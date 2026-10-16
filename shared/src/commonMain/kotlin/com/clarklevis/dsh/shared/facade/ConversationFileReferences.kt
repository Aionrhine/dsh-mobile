package com.clarklevis.dsh.shared.facade

/** 链接目标由 Markdown AST 提供；普通代码仅能匹配本轮已知交付文件。 */
object ConversationFileReferences {
    fun filePath(link: String): String? {
        val value = link.removePrefix("<").removeSuffix(">")
        val withoutLine = value.replace(Regex("#L[0-9]+(?:-L?[0-9]+)?$"), "")
        val path = when {
            withoutLine.startsWith("file://", ignoreCase = true) -> {
                val local = withoutLine.drop(7)
                when {
                    local.startsWith("/") -> local
                    local.startsWith("localhost/", ignoreCase = true) -> local.drop(9)
                    else -> return null
                }
            }
            Regex("^[A-Za-z]:(?:[/\\\\]|%2[fF]|%5[cC])").containsMatchIn(withoutLine) -> withoutLine
            Regex("^[A-Za-z][A-Za-z0-9+.-]*:").containsMatchIn(withoutLine) -> return null
            withoutLine.startsWith("#") || withoutLine.startsWith("//") -> return null
            else -> withoutLine
        }
        return decodePercent(path)?.takeIf { it.isNotBlank() && '\u0000' !in it }
    }

    fun knownPath(code: String, paths: List<String>): String? {
        if (code in paths) return code
        if ('/' in code || '\\' in code) return null
        return paths.filter { it.replace('\\', '/').substringAfterLast('/') == code }.singleOrNull()
    }

    private fun decodePercent(value: String): String? {
        val output = mutableListOf<Byte>()
        var index = 0
        while (index < value.length) {
            if (value[index] == '%') {
                if (index + 2 >= value.length) return null
                val byte = value.substring(index + 1, index + 3).toIntOrNull(16) ?: return null
                output += byte.toByte()
                index += 3
            } else {
                val end = value.indexOf('%', index).takeIf { it >= 0 } ?: value.length
                output += value.substring(index, end).encodeToByteArray().toList()
                index = end
            }
        }
        return runCatching { output.toByteArray().decodeToString(throwOnInvalidSequence = true) }.getOrNull()
    }
}
