package com.clarklevis.dsh.android

import com.clarklevis.dsh.shared.facade.SharedWorkspaceFileCacheLookup
import com.clarklevis.dsh.shared.facade.SharedWorkspaceFileCompletion
import java.io.File
import java.security.MessageDigest
import java.util.UUID

/** 可被系统清理的磁盘缓存。版本目录不可变，避免覆盖仍在预览的文件。 */
internal class AndroidWorkspacePreviewCache(private val root: File, private val gatewayId: String) {
    fun find(version: SharedWorkspaceFileCacheLookup): File? = runCatching {
        val directory = directory(version.sessionId, version.path, version.size, version.modifiedAt)
        val file = File(directory, safeName(version.name))
        val expected = File(directory, "sha256").readText()
        if (!file.isFile || file.length() != version.size || digest(file) != expected) {
            directory.deleteRecursively()
            return null
        }
        directory.setLastModified(System.currentTimeMillis())
        file
    }.getOrNull()

    fun store(source: File, completion: SharedWorkspaceFileCompletion): File? {
        val modifiedAt = completion.modifiedAt ?: return null
        if (completion.purpose != "preview") return null
        val directory = directory(completion.sessionId, completion.path, completion.size, modifiedAt)
        val staging = File(root, ".pending-${UUID.randomUUID()}")
        return try {
            check(staging.mkdirs())
            val file = File(staging, safeName(completion.name))
            source.copyTo(file)
            File(staging, "sha256").writeText(completion.sha256)
            if (directory.exists()) directory.deleteRecursively()
            check(staging.renameTo(directory))
            prune(directory)
            File(directory, file.name)
        } catch (_: Exception) {
            staging.deleteRecursively()
            null // 缓存写入失败仍可打开已经完成校验的下载文件。
        }
    }

    private fun directory(sessionId: String, path: String, size: Long, modifiedAt: Double): File {
        val identity = listOf(gatewayId, sessionId, path, size.toString(), modifiedAt.toString())
            .joinToString("") { "${it.length}:$it" }
        val key = MessageDigest.getInstance("SHA-256").digest(identity.toByteArray())
            .joinToString("") { "%02x".format(it) }
        return File(root, key)
    }

    private fun safeName(name: String): String = File(name).name.takeUnless {
        it.isBlank() || it == "." || it == ".." || it == "sha256"
    } ?: "file"

    private fun digest(file: File): String {
        val sha = MessageDigest.getInstance("SHA-256")
        file.inputStream().buffered().use { input ->
            val buffer = ByteArray(64 * 1024)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                sha.update(buffer, 0, count)
            }
        }
        return sha.digest().joinToString("") { "%02x".format(it) }
    }

    private fun prune(current: File) {
        val entries = root.listFiles()?.filter { it.isDirectory && !it.name.startsWith(".") }
            ?.sortedByDescending(File::lastModified).orEmpty()
        var bytes = 0L
        entries.forEach { directory ->
            bytes += directory.listFiles().orEmpty().sumOf(File::length)
            if (directory != current && bytes > MAX_BYTES) directory.deleteRecursively()
        }
    }

    private companion object {
        const val MAX_BYTES = 512L * 1024 * 1024
    }
}
