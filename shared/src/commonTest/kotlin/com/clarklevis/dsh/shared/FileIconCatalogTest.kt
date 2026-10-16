package com.clarklevis.dsh.shared

import com.clarklevis.dsh.shared.facade.FileIconCatalog
import com.clarklevis.dsh.shared.facade.FileIconKind
import kotlin.test.Test
import kotlin.test.assertEquals

class FileIconCatalogTest {
    @Test
    fun knownExtensionsWinOverGenericOrIncorrectMimeTypes() {
        assertEquals(FileIconKind.PDF, FileIconCatalog.resolve("报告.PDF", "application/octet-stream"))
        assertEquals(FileIconKind.KT, FileIconCatalog.resolve("C:\\workspace\\FilePreview.KT", "text/plain"))
        assertEquals(FileIconKind.CPP, FileIconCatalog.resolve("src/main.cxx", "text/plain"))
        assertEquals(FileIconKind.XLSX, FileIconCatalog.resolve("表格.xlsx", "application/pdf"))
        assertEquals(FileIconKind.JPG, FileIconCatalog.resolve("photo.JPEG", null))
        assertEquals(FileIconKind.SEVEN_Z, FileIconCatalog.resolve("archive.7z", null))
        assertEquals(FileIconKind.APK, FileIconCatalog.resolve("release.apk", null))
    }

    @Test
    fun specialNamesAndCompoundSuffixesHavePriority() {
        val cases = mapOf(
            ".env" to FileIconKind.ENV,
            ".env.production" to FileIconKind.ENV,
            "build.gradle.kts" to FileIconKind.GRADLE,
            "settings.gradle.kts" to FileIconKind.GRADLE,
            "CMakeLists.txt" to FileIconKind.CMAKE,
            "GNUmakefile" to FileIconKind.MAKE,
            "Makefile" to FileIconKind.MAKE,
            "Dockerfile.release" to FileIconKind.CODE,
            ".gitignore" to FileIconKind.CONF,
            "LICENSE" to FileIconKind.TXT
        )
        cases.forEach { (name, expected) ->
            assertEquals(expected, FileIconCatalog.resolve("/workspace/$name", "text/plain"), name)
        }
    }

    @Test
    fun mimeFallbackNormalizesCaseAndParameters() {
        assertEquals(FileIconKind.PDF, FileIconCatalog.resolve("download", " APPLICATION/PDF ; charset=binary"))
        assertEquals(FileIconKind.DOCX, FileIconCatalog.resolve("download", "application/vnd.openxmlformats-officedocument.wordprocessingml.document"))
        assertEquals(FileIconKind.JSON, FileIconCatalog.resolve("response", "application/json; charset=utf-8"))
        assertEquals(FileIconKind.PNG, FileIconCatalog.resolve("photo", "image/png"))
        assertEquals(FileIconKind.MP3, FileIconCatalog.resolve("audio", "audio/mpeg"))
        assertEquals(FileIconKind.MP4, FileIconCatalog.resolve("video", "video/mp4"))
        assertEquals(FileIconKind.DOCUMENT, FileIconCatalog.resolve("notes", "text/x-custom"))
        assertEquals(FileIconKind.CODE, FileIconCatalog.resolve("source", "text/x-source"))
        assertEquals(FileIconKind.BINARY, FileIconCatalog.resolve("data", "application/octet-stream"))
    }

    @Test
    fun unknownFilesDoNotInheritExtensionsFromTheirParentDirectory() {
        assertEquals(FileIconKind.UNKNOWN, FileIconCatalog.resolve("/folder.pdf/attachment", null))
        assertEquals(FileIconKind.UNKNOWN, FileIconCatalog.resolve("/workspace/.environment", null))
        assertEquals(FileIconKind.UNKNOWN, FileIconCatalog.resolve("report.unrecognized", "application/x-custom"))
        assertEquals(FileIconKind.UNKNOWN, FileIconCatalog.resolve("", null))
        assertEquals(FileIconKind.BINARY, FileIconCatalog.resolve("data.BIN", null))
        assertEquals(FileIconKind.UNKNOWN, FileIconCatalog.resolve("archive.tar.gz", null))
        assertEquals(FileIconKind.UNKNOWN, FileIconCatalog.resolve("release.aab", null))
        assertEquals(FileIconKind.UNKNOWN, FileIconCatalog.resolve("photo.heic", "image/heic"))
        assertEquals(FileIconKind.UNKNOWN, FileIconCatalog.resolve("song.wav", "audio/wav"))
        assertEquals(FileIconKind.UNKNOWN, FileIconCatalog.resolve("video.mov", "video/quicktime"))
        assertEquals(FileIconKind.UNKNOWN, FileIconCatalog.resolve("photo", "image/x-custom"))
    }

    @Test
    fun backgroundsMatchTheApprovedLightAndDarkPalette() {
        assertEquals(0xFCEEED, FileIconKind.PDF.cardBackgroundRgb(dark = false))
        assertEquals(0x3A1F1E, FileIconKind.PDF.cardBackgroundRgb(dark = true))
        assertEquals(0xEBF6F1, FileIconKind.XLSX.cardBackgroundRgb(dark = false))
        assertEquals(0xF0F1FD, FileIconKind.KT.cardBackgroundRgb(dark = false))
    }
}
