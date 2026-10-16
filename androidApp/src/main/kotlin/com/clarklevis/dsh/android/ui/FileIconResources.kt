package com.clarklevis.dsh.android.ui

import androidx.annotation.DrawableRes
import com.clarklevis.dsh.android.R
import com.clarklevis.dsh.shared.facade.FileIconKind

// 由 scripts/generate_file_icon_assets.py 生成，使用静态资源 ID，避免运行时资源反射。
@DrawableRes
internal fun FileIconKind.drawableResource(): Int = when (this) {
    FileIconKind.PDF -> R.drawable.ic_file_pdf
    FileIconKind.DOC -> R.drawable.ic_file_doc
    FileIconKind.DOCX -> R.drawable.ic_file_docx
    FileIconKind.TXT -> R.drawable.ic_file_txt
    FileIconKind.MD -> R.drawable.ic_file_md
    FileIconKind.RTF -> R.drawable.ic_file_rtf
    FileIconKind.ODT -> R.drawable.ic_file_odt
    FileIconKind.EPUB -> R.drawable.ic_file_epub
    FileIconKind.XLS -> R.drawable.ic_file_xls
    FileIconKind.XLSX -> R.drawable.ic_file_xlsx
    FileIconKind.CSV -> R.drawable.ic_file_csv
    FileIconKind.TSV -> R.drawable.ic_file_tsv
    FileIconKind.ODS -> R.drawable.ic_file_ods
    FileIconKind.PPT -> R.drawable.ic_file_ppt
    FileIconKind.PPTX -> R.drawable.ic_file_pptx
    FileIconKind.ODP -> R.drawable.ic_file_odp
    FileIconKind.C -> R.drawable.ic_file_c
    FileIconKind.CPP -> R.drawable.ic_file_cpp
    FileIconKind.H -> R.drawable.ic_file_h
    FileIconKind.HPP -> R.drawable.ic_file_hpp
    FileIconKind.CSHARP -> R.drawable.ic_file_csharp
    FileIconKind.JAVA -> R.drawable.ic_file_java
    FileIconKind.KT -> R.drawable.ic_file_kt
    FileIconKind.SWIFT -> R.drawable.ic_file_swift
    FileIconKind.OBJC -> R.drawable.ic_file_objc
    FileIconKind.OBJCPP -> R.drawable.ic_file_objcpp
    FileIconKind.PY -> R.drawable.ic_file_py
    FileIconKind.IPYNB -> R.drawable.ic_file_ipynb
    FileIconKind.JS -> R.drawable.ic_file_js
    FileIconKind.JSX -> R.drawable.ic_file_jsx
    FileIconKind.TS -> R.drawable.ic_file_ts
    FileIconKind.TSX -> R.drawable.ic_file_tsx
    FileIconKind.HTML -> R.drawable.ic_file_html
    FileIconKind.CSS -> R.drawable.ic_file_css
    FileIconKind.SCSS -> R.drawable.ic_file_scss
    FileIconKind.VUE -> R.drawable.ic_file_vue
    FileIconKind.SVELTE -> R.drawable.ic_file_svelte
    FileIconKind.GO -> R.drawable.ic_file_go
    FileIconKind.RS -> R.drawable.ic_file_rs
    FileIconKind.DART -> R.drawable.ic_file_dart
    FileIconKind.RB -> R.drawable.ic_file_rb
    FileIconKind.PHP -> R.drawable.ic_file_php
    FileIconKind.SH -> R.drawable.ic_file_sh
    FileIconKind.PS1 -> R.drawable.ic_file_ps1
    FileIconKind.SQL -> R.drawable.ic_file_sql
    FileIconKind.JSON -> R.drawable.ic_file_json
    FileIconKind.YAML -> R.drawable.ic_file_yaml
    FileIconKind.XML -> R.drawable.ic_file_xml
    FileIconKind.TOML -> R.drawable.ic_file_toml
    FileIconKind.INI -> R.drawable.ic_file_ini
    FileIconKind.CONF -> R.drawable.ic_file_conf
    FileIconKind.ENV -> R.drawable.ic_file_env
    FileIconKind.GRADLE -> R.drawable.ic_file_gradle
    FileIconKind.CMAKE -> R.drawable.ic_file_cmake
    FileIconKind.MAKE -> R.drawable.ic_file_make
    FileIconKind.BAT -> R.drawable.ic_file_bat
    FileIconKind.PNG -> R.drawable.ic_file_png
    FileIconKind.JPG -> R.drawable.ic_file_jpg
    FileIconKind.SVG -> R.drawable.ic_file_svg
    FileIconKind.GIF -> R.drawable.ic_file_gif
    FileIconKind.WEBP -> R.drawable.ic_file_webp
    FileIconKind.MP3 -> R.drawable.ic_file_mp3
    FileIconKind.MP4 -> R.drawable.ic_file_mp4
    FileIconKind.ZIP -> R.drawable.ic_file_zip
    FileIconKind.RAR -> R.drawable.ic_file_rar
    FileIconKind.SEVEN_Z -> R.drawable.ic_file_7z
    FileIconKind.APK -> R.drawable.ic_file_apk
    FileIconKind.IPA -> R.drawable.ic_file_ipa
    FileIconKind.DOCUMENT -> R.drawable.ic_file_document
    FileIconKind.CODE -> R.drawable.ic_file_code
    FileIconKind.BINARY -> R.drawable.ic_file_binary
    FileIconKind.UNKNOWN -> R.drawable.ic_file_unknown
}
