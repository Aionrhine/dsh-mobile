package com.clarklevis.dsh.android.ui

import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.text.TextPaint
import android.text.method.LinkMovementMethod
import android.util.TypedValue
import android.view.Gravity
import android.view.ViewGroup
import android.widget.HorizontalScrollView
import android.widget.TableLayout
import android.widget.TableRow
import android.widget.Toast
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.LocalActivity
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import com.clarklevis.dsh.android.R
import com.clarklevis.dsh.android.localization.appText
import com.clarklevis.dsh.shared.facade.MarkdownTableExport
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.commonmark.ext.gfm.tables.TableCell

@Composable
internal fun DshMarkdownTableCard(table: DshTableData, textSizeSp: Float, onOpenFile: ((String) -> Unit)?, copyMarkdown: String) {
    val context = LocalContext.current
    val activity = LocalActivity.current
    var messageAnchor by remember { mutableStateOf<androidx.compose.ui.unit.IntOffset?>(null) }
    var selection by remember { mutableStateOf<String?>(null) }
    var fullscreen by rememberSaveable { mutableStateOf(false) }
    var fullscreenSnapshot by remember { mutableStateOf(table) }
    var originalOrientation by rememberSaveable { mutableStateOf<Int?>(null) }
    val closeFullscreen: () -> Unit = {
        fullscreen = false
        val orientation = originalOrientation
        originalOrientation = null
        if (orientation != null) activity?.requestedOrientation = orientation
    }
    val colors = dshDocumentColors()
    Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).background(colors.toolbar).testTag("markdown-table-card")) {
        DshTableActions(table, onExpand = { fullscreenSnapshot = table; fullscreen = true })
        DshTableGrid(table, textSizeSp, onOpenFile, onMessageMenu = { messageAnchor = it })
    }
    DshPointMenu(messageAnchor, { messageAnchor = null }) {
        DshMenuItem(text = { Text(appText("复制")) }, onClick = {
            messageAnchor = null
            context.copyMarkdownText(markdownPlainText(copyMarkdown))
        })
        DshMenuItem(text = { Text(appText("选择文字")) }, onClick = {
            messageAnchor = null
            selection = copyMarkdown
        })
    }
    selection?.let { source -> DshMarkdownSelectionPage(source) { selection = null } }
    if (fullscreen) {
        val snapshot = fullscreenSnapshot
        DshDocumentDialog(onDismiss = closeFullscreen) {
            val pageColors = dshDocumentColors()
            Column(Modifier.fillMaxSize().background(pageColors.background)
                .documentPageInsets().testTag("markdown-table-fullscreen")) {
                DshTableActions(snapshot, onClose = closeFullscreen, onRotate = activity?.let { host -> {
                    if (originalOrientation == null) originalOrientation = host.requestedOrientation
                    host.requestedOrientation = if (host.resources.configuration.orientation == android.content.res.Configuration.ORIENTATION_LANDSCAPE) {
                        android.content.pm.ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
                    } else {
                        android.content.pm.ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE
                    }
                } })
                Box(Modifier.weight(1f).fillMaxWidth().padding(horizontal = 20.dp)
                    .padding(top = 12.dp, bottom = 20.dp).clip(RoundedCornerShape(12.dp))
                    .verticalScroll(rememberScrollState())) {
                    DshTableGrid(snapshot, textSizeSp, onOpenFile)
                }
            }
        }
    }
}

@Composable
private fun DshTableActions(table: DshTableData, modifier: Modifier = Modifier,
    onExpand: (() -> Unit)? = null, onClose: (() -> Unit)? = null, onRotate: (() -> Unit)? = null) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var copied by remember { mutableStateOf(false) }
    var pendingCsvPath by rememberSaveable { mutableStateOf<String?>(null) }
    val exporter = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("text/csv")) { uri ->
        val file = pendingCsvPath?.let { java.io.File(it) }
        pendingCsvPath = null
        if (file != null) scope.launch {
            val result = runCatching {
                withContext(Dispatchers.IO) {
                    if (uri != null) requireNotNull(context.contentResolver.openOutputStream(uri, "w")).use { output ->
                        file.inputStream().use { it.copyTo(output) }
                    }
                }
            }
            withContext(Dispatchers.IO) { file.delete() }
            if (uri != null) Toast.makeText(context, appText(if (result.isSuccess) "已保存" else "保存失败"), Toast.LENGTH_SHORT).show()
        }
    }
    LaunchedEffect(copied) { if (copied) { delay(1800); copied = false } }
    val colors = dshDocumentColors()
    val buttons: @Composable () -> Unit = {
        Row(verticalAlignment = Alignment.CenterVertically) {
            if (copied && onClose == null) Text(appText("已复制"), fontSize = 12.sp, color = colors.icon)
            if (onRotate != null) IconButton(onClick = onRotate, modifier = Modifier.size(44.dp)) {
                Icon(painterResource(R.drawable.ic_table_rotate), appText("旋转屏幕"), Modifier.size(20.dp), tint = colors.icon)
            }
            IconButton(onClick = { context.copyMarkdownText(MarkdownTableExport.plainText(table.plainRows)); copied = true },
                modifier = Modifier.size(44.dp)) {
                Icon(painterResource(R.drawable.ic_table_copy), appText("复制表格"), Modifier.size(20.dp), tint = colors.icon)
            }
            IconButton(onClick = {
                scope.launch {
                    runCatching {
                        withContext(Dispatchers.IO) {
                            java.io.File.createTempFile("markdown-table-", ".csv", context.cacheDir).apply {
                                writeText(MarkdownTableExport.csv(table.plainRows), Charsets.UTF_8)
                            }
                        }
                    }.onSuccess { file ->
                        pendingCsvPath = file.absolutePath
                        exporter.launch("table.csv")
                    }.onFailure {
                        Toast.makeText(context, appText("保存失败"), Toast.LENGTH_SHORT).show()
                    }
                }
            }, modifier = Modifier.size(44.dp)) {
                Icon(painterResource(R.drawable.ic_table_download), appText("下载 CSV"), Modifier.size(20.dp), tint = colors.icon)
            }
            if (onExpand != null) IconButton(onClick = onExpand, modifier = Modifier.size(44.dp)) {
                Icon(painterResource(R.drawable.ic_table_expand), appText("全屏浏览表格"), Modifier.size(20.dp), tint = colors.icon)
            }
        }
    }
    if (onClose != null) {
        DshDocumentPageHeader(appText("表格"), "markdown-table-close", onClose) { buttons() }
    } else {
        Row(modifier.fillMaxWidth().heightIn(min = 44.dp).padding(start = 12.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(appText("表格"), fontSize = 12.sp, color = colors.icon)
            Spacer(Modifier.weight(1f))
            buttons()
        }
    }
}

private data class TableGridKey(val table: DshTableData, val size: Float, val density: Float, val text: Int, val border: Int, val header: Int, val odd: Int, val background: Int)

/** 每列使用内容测量后的 96～260dp 宽度，超出视口横向滚动，绝不按屏宽均分。 */
@Composable
private fun DshTableGrid(table: DshTableData, sizeSp: Float, onOpenFile: ((String) -> Unit)?,
    onMessageMenu: ((androidx.compose.ui.unit.IntOffset?) -> Unit)? = null) {
    val density = LocalDensity.current
    val colors = dshDocumentColors()
    val bodySize = if (sizeSp <= 14f) 13f else 17f
    val key = TableGridKey(table, with(density) { bodySize.sp.toPx() }, density.density,
        colors.foreground.toArgb(), colors.border.toArgb(), colors.header.toArgb(), colors.alternate.toArgb(), colors.background.toArgb())
    var savedScrollX by rememberSaveable { mutableStateOf(0) }
    val currentOpen by rememberUpdatedState(onOpenFile)
    val currentMenu by rememberUpdatedState(onMessageMenu)
    AndroidView(
        factory = { context -> HorizontalScrollView(context).apply {
            isHorizontalScrollBarEnabled = true
            isFillViewport = false
            setOnScrollChangeListener { _, x, _, _, _ -> savedScrollX = x }
            addView(TableLayout(context), ViewGroup.LayoutParams(-2, -2))
        } },
        update = { scroll ->
            if (scroll.tag != key) {
                scroll.tag = key
                val layout = scroll.getChildAt(0) as TableLayout
                val restoreX = savedScrollX
                layout.removeAllViews()
                scroll.post { scroll.scrollTo(restoreX, 0) }
                val paint = TextPaint().apply { textSize = key.size; typeface = Typeface.DEFAULT }
                val widths = List(table.columnCount) { column ->
                    val natural = table.rows.maxOfOrNull { row ->
                        row.getOrNull(column)?.plainText?.lineSequence()?.maxOfOrNull(paint::measureText) ?: 0f
                    } ?: 0f
                    (natural + 24 * key.density).coerceIn(96 * key.density, 260 * key.density).toInt()
                }
                table.rows.forEachIndexed { rowIndex, cells ->
                    val row = TableRow(scroll.context)
                    repeat(table.columnCount) { column ->
                        val cell = cells.getOrNull(column)
                        row.addView(DshMarkdownTextView(scroll.context).apply {
                            setTextIsSelectable(false)
                            if (onMessageMenu == null) setOnLongClickListener(null)
                            isLongClickable = onMessageMenu != null
                            onMessageMenuRequested = { currentMenu?.invoke(it) }
                            includeFontPadding = false
                            setTextSize(TypedValue.COMPLEX_UNIT_PX, key.size)
                            setTextColor(key.text)
                            if (rowIndex == 0) setTypeface(typeface, Typeface.BOLD)
                            gravity = Gravity.TOP or when (cell?.alignment) {
                                TableCell.Alignment.CENTER -> Gravity.CENTER_HORIZONTAL
                                TableCell.Alignment.RIGHT -> Gravity.RIGHT
                                else -> Gravity.LEFT
                            }
                            val pad = (12 * key.density).toInt()
                            setPadding(pad, pad, pad, pad)
                            setLineSpacing(3 * key.density, 1f)
                            setText(cell?.text ?: "")
                            this.onOpenFile = { currentOpen?.invoke(it) }
                            linksClickable = true
                            movementMethod = LinkMovementMethod.getInstance()
                            background = GradientDrawable().apply {
                                setColor(if (rowIndex == 0) key.header else if (rowIndex % 2 == 0) key.odd else key.background)
                                setStroke((.5f * key.density).toInt().coerceAtLeast(1), key.border)
                            }
                        }, TableRow.LayoutParams(widths[column], -1))
                    }
                    layout.addView(row, TableLayout.LayoutParams(-2, -2))
                }
            }
        },
        modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).testTag("markdown-table-grid")
    )
}
