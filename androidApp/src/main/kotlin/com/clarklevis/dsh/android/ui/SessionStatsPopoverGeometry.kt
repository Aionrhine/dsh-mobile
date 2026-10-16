package com.clarklevis.dsh.android.ui

import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Outline
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntRect
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.PopupPositionProvider

internal data class SessionStatsPopoverPlacement(
    val position: IntOffset,
    val arrowX: Float,
    val pointsUp: Boolean,
    val transformOrigin: TransformOrigin,
    val surfaceHeightLimit: Int
)

internal class SessionStatsPopoverPositionProvider(
    private val shadowPadding: Int,
    private val gap: Int,
    private val onPositioned: (SessionStatsPopoverPlacement) -> Unit
) : PopupPositionProvider {
    override fun calculatePosition(
        anchorBounds: IntRect,
        windowSize: IntSize,
        layoutDirection: LayoutDirection,
        popupContentSize: IntSize
    ): IntOffset {
        val placement = calculateSessionStatsPopoverPlacement(
            anchorBounds, windowSize, popupContentSize, layoutDirection, shadowPadding, gap
        )
        onPositioned(placement)
        return placement.position
    }
}

internal fun calculateSessionStatsPopoverPlacement(
    anchorBounds: IntRect,
    windowSize: IntSize,
    popupContentSize: IntSize,
    layoutDirection: LayoutDirection,
    shadowPadding: Int,
    gap: Int
): SessionStatsPopoverPlacement {
    val width = popupContentSize.width.coerceAtLeast(1)
    val height = popupContentSize.height.coerceAtLeast(1)
    val maximumX = (windowSize.width - width).coerceAtLeast(0)
    val maximumY = (windowSize.height - height).coerceAtLeast(0)
    val preferredX = if (layoutDirection == LayoutDirection.Ltr) {
        anchorBounds.right - width + shadowPadding
    } else {
        anchorBounds.left - shadowPadding
    }
    val aboveY = anchorBounds.top - gap - height + shadowPadding
    val belowY = anchorBounds.bottom + gap - shadowPadding
    val displaysAbove = when {
        aboveY >= 0 -> true
        belowY <= maximumY -> false
        else -> anchorBounds.top >= windowSize.height - anchorBounds.bottom
    }
    val position = IntOffset(
        preferredX.coerceIn(0, maximumX),
        (if (displaysAbove) aboveY else belowY).coerceIn(0, maximumY)
    )
    val anchorCenterX = (anchorBounds.left + anchorBounds.right) / 2f
    val anchorCenterY = (anchorBounds.top + anchorBounds.bottom) / 2f
    return SessionStatsPopoverPlacement(
        position = position,
        arrowX = anchorCenterX - position.x - shadowPadding,
        pointsUp = !displaysAbove,
        // 动画作用于含阴影留白的整个 Popup，原点允许落在弹窗矩形外的胶囊中心。
        transformOrigin = TransformOrigin(
            (anchorCenterX - position.x) / width,
            (anchorCenterY - position.y) / height
        ),
        surfaceHeightLimit = (
            if (displaysAbove) anchorBounds.top - gap - shadowPadding
            else windowSize.height - anchorBounds.bottom - gap - shadowPadding
        ).coerceAtLeast(1)
    )
}

/** 箭头与圆角卡片使用同一轮廓，避免描边和阴影在接缝处重叠。 */
internal data class SessionStatsPopoverShape(
    val arrowX: Float,
    val pointsUp: Boolean
) : Shape {
    override fun createOutline(size: Size, layoutDirection: LayoutDirection, density: Density): Outline {
        val arrowHeight = minOf(with(density) { 8.dp.toPx() }, size.height / 3)
        val top = arrowHeight
        val bottom = size.height
        val radius = minOf(with(density) { 24.dp.toPx() }, (bottom - top) / 2, size.width / 2)
        val halfArrow = minOf(with(density) { 10.dp.toPx() }, (size.width / 2 - radius).coerceAtLeast(0f))
        val center = arrowX.coerceIn(radius + halfArrow, size.width - radius - halfArrow)
        val tipRoundness = minOf(with(density) { 2.dp.toPx() }, halfArrow / 2, arrowHeight / 2)
        fun y(value: Float) = if (pointsUp) value else size.height - value
        val path = Path().apply {
            moveTo(radius, y(top))
            lineTo(center - halfArrow, y(top))
            quadraticTo(center - tipRoundness * 2, y(top), center - tipRoundness, y(tipRoundness))
            quadraticTo(center, y(-tipRoundness), center + tipRoundness, y(tipRoundness))
            quadraticTo(center + tipRoundness * 2, y(top), center + halfArrow, y(top))
            lineTo(size.width - radius, y(top))
            quadraticTo(size.width, y(top), size.width, y(top + radius))
            lineTo(size.width, y(bottom - radius))
            quadraticTo(size.width, y(bottom), size.width - radius, y(bottom))
            lineTo(radius, y(bottom))
            quadraticTo(0f, y(bottom), 0f, y(bottom - radius))
            lineTo(0f, y(top + radius))
            quadraticTo(0f, y(top), radius, y(top))
            close()
        }
        return Outline.Generic(path)
    }
}
