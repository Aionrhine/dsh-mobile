package com.clarklevis.dsh.android.ui

import com.clarklevis.dsh.android.localization.appText
import com.clarklevis.dsh.shared.projection.ToolActivitySummary

private val replacementLines = Regex("替换 (\\d+) → (\\d+) 行")
private val lineCount = Regex("(\\d+) 行")

/** 仅翻译共享格式化器的固定标签；路径、命令和工具描述保持原文。 */
internal fun localizedToolActivitySummary(summary: ToolActivitySummary): ToolActivitySummary {
    val replacement = replacementLines.matchEntire(summary.annotation)
    val lines = lineCount.matchEntire(summary.annotation)
    val annotation = when {
        replacement != null -> appText(
            "替换 %1\$s → %2\$s 行", replacement.groupValues[1], replacement.groupValues[2]
        )
        lines != null -> appText("%1\$s 行", lines.groupValues[1])
        else -> summary.annotation
    }
    return summary.copy(label = appText(summary.label), annotation = annotation)
}
