package com.clarklevis.dsh.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.SheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.dropShadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.shadow.Shadow
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.DpOffset
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch

/** 文件目录和预览共用的圆形操作按钮，图标颜色跟随当前主题。 */
@Composable
internal fun WorkspaceSheetIconButton(
    icon: Int,
    description: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier
) {
    Box(
        modifier.size(52.dp)
            .dropShadow(
                shape = CircleShape,
                shadow = Shadow(
                    radius = 12.dp,
                    color = Color.Black.copy(alpha = 0.14f),
                    offset = DpOffset(0.dp, 3.dp)
                )
            )
            .background(MaterialTheme.colorScheme.surface, CircleShape)
            .clip(CircleShape)
            .clickable(role = Role.Button, onClick = onClick),
        contentAlignment = Alignment.Center
    ) {
        Icon(painterResource(icon), description, Modifier.size(22.dp), tint = MaterialTheme.colorScheme.onSurface)
    }
}

/** 等待退出动效结束再移除弹层，连续点击只触发一次关闭。 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun rememberWorkspaceSheetDismiss(sheetState: SheetState, onDismiss: () -> Unit): () -> Unit {
    val scope = rememberCoroutineScope()
    val currentOnDismiss by rememberUpdatedState(onDismiss)
    var closing by remember(sheetState) { mutableStateOf(false) }
    return {
        if (!closing) {
            closing = true
            scope.launch {
                try {
                    sheetState.hide()
                    if (!sheetState.isVisible) currentOnDismiss()
                } finally {
                    closing = false
                }
            }
        }
    }
}
