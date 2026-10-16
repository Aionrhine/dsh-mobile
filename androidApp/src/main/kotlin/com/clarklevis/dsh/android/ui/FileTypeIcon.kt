package com.clarklevis.dsh.android.ui

import androidx.compose.foundation.Image
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.clarklevis.dsh.shared.facade.FileIconCatalog
import com.clarklevis.dsh.shared.facade.FileIconKind
import com.clarklevis.dsh.shared.facade.FileCardDescription

@Composable
internal fun FileTypeIcon(kind: FileIconKind, modifier: Modifier = Modifier) {
    // 使用 Image 保留矢量原色，不能使用默认带 tint 的 Icon。
    Image(painterResource(kind.drawableResource()), contentDescription = null, modifier = modifier)
}

@Composable
internal fun fileCardColor(kind: FileIconKind): Color =
    Color(0xFF000000.toInt() or kind.cardBackgroundRgb(isSystemInDarkTheme()))

@Composable
internal fun FileReferenceCard(
    path: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    mediaType: String? = null,
    description: String? = null
) {
    val kind = remember(path, mediaType) { FileIconCatalog.resolve(path, mediaType) }
    val summary = remember(description) { FileCardDescription.summary(description) }
    Surface(
        onClick = onClick,
        shape = RoundedCornerShape(12.dp),
        color = fileCardColor(kind),
        contentColor = MaterialTheme.colorScheme.onSurface,
        modifier = modifier.widthIn(max = 320.dp)
    ) {
        Row(
            Modifier.padding(12.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            FileTypeIcon(kind, Modifier.size(48.dp))
            Column(Modifier.weight(1f, fill = false), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(
                    path.replace('\\', '/').substringAfterLast('/'),
                    fontSize = 15.sp,
                    fontWeight = FontWeight.Medium,
                )
                summary?.let {
                    Text(
                        it,
                        fontSize = 12.sp,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        }
    }
}
