#!/usr/bin/env python3
"""从已导出的 Figma SVG 生成双端资源和共享格式清单，不访问网络。"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'Design/file-icons'
MANIFEST = json.loads((SOURCE / 'manifest.json').read_text())
ICONS = MANIFEST['icons']


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')


def mix(color, surface, amount):
    return tuple(int(int(color[i:i + 2], 16) * amount + int(surface[i:i + 2], 16) * (1 - amount) + 0.5) for i in (0, 2, 4))


def generate():
    for icon in ICONS:
        data = (SOURCE / 'svg' / (icon['key'] + '.svg')).read_bytes()
        assert hashlib.sha256(data).hexdigest() == icon['sha256'], f"素材校验失败：{icon['key']}"

    # 使用 Android SDK 自带的转换器，保留原始路径、变换、描边和透明度。
    cache = Path(os.environ.get('GRADLE_USER_HOME', Path.home() / '.gradle')) / 'caches/modules-2/files-2.1'
    groups = ['com.android.tools', 'com.google.guava', 'org.jetbrains.kotlin', 'org.jetbrains']
    jars = [p for group in groups for p in (cache / group).rglob('*.jar') if not any(x in p.name for x in ['-sources', '-javadoc', '-all'])]
    if not any(p.name.startswith('sdk-common-') for p in jars):
        raise SystemExit('缺少 Android sdk-common，请先运行一次 Gradle 构建。')
    classpath = os.pathsep.join(str(p) for p in sorted(jars, reverse=True))
    drawable = ROOT / 'androidApp/src/main/res/drawable'
    with tempfile.TemporaryDirectory(prefix='dsh-file-icons-') as directory:
        java = Path(directory) / 'ConvertFileIcons.java'
        java.write_text('''import com.android.ide.common.vectordrawable.Svg2Vector;
import java.nio.file.*;
public class ConvertFileIcons {
  public static void main(String[] args) throws Exception {
    for (int i = 0; i < args.length; i += 2) {
      try (var output = Files.newOutputStream(Path.of(args[i + 1]))) {
        String errors = Svg2Vector.parseSvgToXml(Path.of(args[i]), output);
        if (!errors.isBlank()) throw new IllegalStateException(args[i] + ": " + errors);
      }
    }
  }
}
''')
        args = [part for icon in ICONS for part in [str(SOURCE / 'svg' / (icon['key'] + '.svg')), str(drawable / ('ic_file_' + icon['key'] + '.xml'))]]
        subprocess.run(['java', '-cp', classpath, str(java), *args], check=True)

    catalog = ROOT / 'DeepSeekHarnessMobile/Resources/Assets.xcassets'
    for icon in ICONS:
        image = catalog / ('FileIcon_' + icon['key'] + '.imageset')
        image.mkdir(exist_ok=True)
        shutil.copyfile(SOURCE / 'svg' / (icon['key'] + '.svg'), image / 'icon.svg')
        write_json(image / 'Contents.json', {'images': [{'filename': 'icon.svg', 'idiom': 'universal'}], 'info': {'author': 'xcode', 'version': 1}, 'properties': {'preserves-vector-representation': True, 'template-rendering-intent': 'original'}})
    for family, color in MANIFEST['colors'].items():
        colors = []
        for theme in ['light', 'dark']:
            values = mix(color, MANIFEST['cardSurface'][theme], MANIFEST['cardTint'][theme])
            entry = {'idiom': 'universal', 'color': {'color-space': 'srgb', 'components': dict(zip(['red', 'green', 'blue', 'alpha'], [*(f'0x{v:02X}' for v in values), '1.000']))}}
            if theme == 'dark':
                entry['appearances'] = [{'appearance': 'luminosity', 'value': 'dark'}]
            colors.append(entry)
        write_json(catalog / ('FileCard_' + family + '.colorset') / 'Contents.json', {'colors': colors, 'info': {'author': 'xcode', 'version': 1}})

    definitions = ',\n'.join(f'    {e["enum"]}("{e["key"]}", "{e["family"]}", 0x{MANIFEST["colors"][e["family"]]})' for e in ICONS)
    aliases = ',\n'.join(f'    "{extension}" to FileIconKind.{e["enum"]}' for e in ICONS for extension in e['extensions'])
    generated = '''package com.clarklevis.dsh.shared.facade

import kotlin.math.roundToInt

// 由 scripts/generate_file_icon_assets.py 生成；格式与颜色来源为 Design/file-icons/manifest.json。
enum class FileIconKind(val assetKey: String, val colorFamily: String, val colorRgb: Int) {
DEFINITIONS;

    fun cardBackgroundRgb(dark: Boolean): Int {
        val amount = if (dark) 0.16 else 0.08
        val surface = if (dark) 0x1C1C1E else 0xFFFFFF
        fun channel(shift: Int): Int =
            (((colorRgb shr shift) and 255) * amount + ((surface shr shift) and 255) * (1 - amount)).roundToInt()
        return (channel(16) shl 16) or (channel(8) shl 8) or channel(0)
    }
}

internal val FILE_ICON_EXTENSIONS: Map<String, FileIconKind> = mapOf(
ALIASES
)
'''.replace('DEFINITIONS', definitions).replace('ALIASES', aliases)
    (ROOT / 'shared/src/commonMain/kotlin/com/clarklevis/dsh/shared/facade/FileIconKind.kt').write_text(generated)
    mappings = '\n'.join(f'    FileIconKind.{e["enum"]} -> R.drawable.ic_file_{e["key"]}' for e in ICONS)
    (ROOT / 'androidApp/src/main/kotlin/com/clarklevis/dsh/android/ui/FileIconResources.kt').write_text('''package com.clarklevis.dsh.android.ui

import androidx.annotation.DrawableRes
import com.clarklevis.dsh.android.R
import com.clarklevis.dsh.shared.facade.FileIconKind

// 由 scripts/generate_file_icon_assets.py 生成，使用静态资源 ID，避免运行时资源反射。
@DrawableRes
internal fun FileIconKind.drawableResource(): Int = when (this) {
''' + mappings + '\n}\n')
    print(f'已生成 {len(ICONS)} 套双端矢量资源、共享清单和 {len(MANIFEST["colors"])} 组卡片颜色。')


if __name__ == '__main__':
    generate()
