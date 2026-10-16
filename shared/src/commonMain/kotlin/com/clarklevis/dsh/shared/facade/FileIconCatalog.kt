package com.clarklevis.dsh.shared.facade

/** 文件类型只决定图标，预览和下载能力继续由原有文件流程判断。 */
object FileIconCatalog {
    fun resolve(name: String, mediaType: String?): FileIconKind {
        val fileName = name.replace('\\', '/').substringAfterLast('/').trim().lowercase()
        when {
            fileName == ".env" || fileName.startsWith(".env.") -> return FileIconKind.ENV
            fileName.endsWith(".gradle.kts") -> return FileIconKind.GRADLE
            fileName == "cmakelists.txt" -> return FileIconKind.CMAKE
            fileName == "makefile" || fileName == "gnumakefile" -> return FileIconKind.MAKE
            fileName == "dockerfile" || fileName.startsWith("dockerfile.") -> return FileIconKind.CODE
            fileName in setOf(".gitignore", ".gitattributes", ".dockerignore", ".npmrc") -> return FileIconKind.CONF
            fileName == ".editorconfig" -> return FileIconKind.INI
            fileName in setOf("readme", "license", "licence", "notice") -> return FileIconKind.TXT
        }
        val extension = fileName.substringAfterLast('.', missingDelimiterValue = "")
        FILE_ICON_EXTENSIONS[extension]?.let { return it }
        val mime = mediaType?.substringBefore(';')?.trim()?.lowercase().orEmpty()
        MIME_ICONS[mime]?.let { return it }
        return when {
            mime.startsWith("text/") -> FileIconKind.DOCUMENT
            mime == "application/octet-stream" -> FileIconKind.BINARY
            else -> FileIconKind.UNKNOWN
        }
    }

    private val MIME_ICONS = mapOf(
        "application/pdf" to FileIconKind.PDF,
        "application/msword" to FileIconKind.DOC,
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document" to FileIconKind.DOCX,
        "application/vnd.ms-excel" to FileIconKind.XLS,
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" to FileIconKind.XLSX,
        "application/vnd.ms-powerpoint" to FileIconKind.PPT,
        "application/vnd.openxmlformats-officedocument.presentationml.presentation" to FileIconKind.PPTX,
        "application/vnd.oasis.opendocument.text" to FileIconKind.ODT,
        "application/vnd.oasis.opendocument.spreadsheet" to FileIconKind.ODS,
        "application/vnd.oasis.opendocument.presentation" to FileIconKind.ODP,
        "application/epub+zip" to FileIconKind.EPUB,
        "application/rtf" to FileIconKind.RTF,
        "text/rtf" to FileIconKind.RTF,
        "text/plain" to FileIconKind.TXT,
        "text/markdown" to FileIconKind.MD,
        "text/csv" to FileIconKind.CSV,
        "text/tab-separated-values" to FileIconKind.TSV,
        "application/json" to FileIconKind.JSON,
        "application/ld+json" to FileIconKind.JSON,
        "application/xml" to FileIconKind.XML,
        "text/xml" to FileIconKind.XML,
        "application/yaml" to FileIconKind.YAML,
        "text/yaml" to FileIconKind.YAML,
        "application/toml" to FileIconKind.TOML,
        "text/html" to FileIconKind.HTML,
        "text/css" to FileIconKind.CSS,
        "text/javascript" to FileIconKind.JS,
        "application/javascript" to FileIconKind.JS,
        "application/typescript" to FileIconKind.TS,
        "text/typescript" to FileIconKind.TS,
        "text/x-kotlin" to FileIconKind.KT,
        "text/x-swift" to FileIconKind.SWIFT,
        "text/x-java-source" to FileIconKind.JAVA,
        "text/x-python" to FileIconKind.PY,
        "text/x-c" to FileIconKind.C,
        "text/x-c++src" to FileIconKind.CPP,
        "text/x-source" to FileIconKind.CODE,
        "application/x-sh" to FileIconKind.SH,
        "application/sql" to FileIconKind.SQL,
        "image/jpeg" to FileIconKind.JPG,
        "image/png" to FileIconKind.PNG,
        "image/svg+xml" to FileIconKind.SVG,
        "image/gif" to FileIconKind.GIF,
        "image/webp" to FileIconKind.WEBP,
        "audio/mpeg" to FileIconKind.MP3,
        "video/mp4" to FileIconKind.MP4,
        "application/zip" to FileIconKind.ZIP,
        "application/x-zip-compressed" to FileIconKind.ZIP,
        "application/vnd.rar" to FileIconKind.RAR,
        "application/x-rar-compressed" to FileIconKind.RAR,
        "application/x-7z-compressed" to FileIconKind.SEVEN_Z,
        "application/vnd.android.package-archive" to FileIconKind.APK
    )
}
