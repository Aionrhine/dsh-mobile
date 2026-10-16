package com.clarklevis.dsh.shared.facade

/** 保留卡片简介与页数，去掉末尾括号内展开的内容清单。 */
object FileCardDescription {
    fun summary(description: String?): String? {
        val text = description?.trim()?.replace(WHITESPACE, " ")?.takeIf { it.isNotEmpty() }
            ?: return null
        val candidate = text.trimEnd('。', '.', '；', ';', ' ')
        if (candidate.lastOrNull() !in listOf('）', ')')) return text
        val closing = ArrayDeque<Char>()
        for (index in candidate.indices.reversed()) {
            when (val character = candidate[index]) {
                ')', '）' -> closing.addLast(character)
                '(', '（' -> {
                    val expected = if (character == '(') ')' else '）'
                    if (closing.lastOrNull() != expected) return text
                    closing.removeLast()
                    if (closing.isEmpty()) {
                        val details = candidate.substring(index + 1, candidate.lastIndex)
                        if (details.none { it in "/／、,，;；" }) return text
                        return candidate.substring(0, index).trimEnd().takeIf { it.isNotEmpty() }
                    }
                }
            }
        }
        return text
    }

    private val WHITESPACE = Regex("\\s+")
}
