package com.clarklevis.dsh.shared

import com.clarklevis.dsh.shared.facade.SharedWorkspaceFileStore
import kotlin.test.*

class WorkspacePreviewCacheFlowTest {
    @Test
    fun matchingCacheOpensWithoutStartingATransfer() {
        val store = SharedWorkspaceFileStore()
        val lookup = resolve(store)
        assertEquals("a.txt", lookup.cacheLookup?.path)
        assertNull(lookup.request)
        val hit = store.completeCacheLookup("r1", true)
        assertEquals(10.5, hit.cacheHit?.modifiedAt)
        assertNull(hit.request)
        assertNull(hit.completion)
    }

    @Test
    fun cacheMissDownloadsVerifiesAndChecksRemoteVersionAgain() {
        val store = SharedWorkspaceFileStore()
        resolve(store)
        assertEquals("file-download-open", store.completeCacheLookup("r1", false).request?.requestType)
        opened(store)
        val finished = eof(store)
        assertNull(finished.completion)
        assertEquals("aGVsbG8=", finished.appendBase64Data)
        assertEquals("file-resolve", finished.request?.requestType)
        val verified = store.acceptFrame(resolved("t1-verify"))
        assertEquals(10.5, verified.completion?.modifiedAt)
        assertEquals(HASH, verified.completion?.sha256)
    }

    @Test
    fun changedDuringDownloadNeverStoresOldVersionMetadata() {
        val store = SharedWorkspaceFileStore()
        resolve(store)
        store.completeCacheLookup("r1", false)
        opened(store)
        eof(store)
        val changed = store.acceptFrame(resolved("t1-verify", version = "11"))
        assertNotNull(changed.completion)
        assertNull(changed.completion.modifiedAt)
    }

    @Test
    fun missingVersionFallsBackToDownloadWithoutCache() {
        val store = SharedWorkspaceFileStore()
        store.resolve("s1", "a.txt", "r1", true, true)
        val result = store.acceptFrame(resolved("r1", version = "null"))
        assertEquals("file-download-open", result.request?.requestType)
        assertNull(result.cacheLookup)
        opened(store)
        assertNull(eof(store).completion?.modifiedAt)
    }

    @Test
    fun cancellationAndResetIgnoreLateCacheResultsAndVerification() {
        val store = SharedWorkspaceFileStore()
        resolve(store)
        store.cancel()
        assertNull(store.completeCacheLookup("r1", true).cacheHit)
        assertNull(store.completeCacheLookup("r1", false).request)
        resolve(store)
        store.completeCacheLookup("r1", false)
        opened(store)
        eof(store)
        store.reset("s2")
        assertNull(store.acceptFrame(resolved("t1-verify")).completion)
    }

    @Test
    fun verificationFailureStillOpensIntegrityCheckedDownloadWithoutCaching() {
        val store = SharedWorkspaceFileStore()
        resolve(store)
        store.completeCacheLookup("r1", false)
        opened(store)
        eof(store)
        assertNull(store.requestFailed("file-resolve", "old", "old").completion)
        val failed = store.requestFailed("file-resolve", "missing", "t1-verify")
        assertNotNull(failed.completion)
        assertNull(failed.completion.modifiedAt)
        assertNull(failed.snapshot.lastError)
    }

    @Test
    fun mismatchingCallbacksAndConcurrentOpensCannotConsumeCacheLookup() {
        val store = SharedWorkspaceFileStore()
        resolve(store)
        assertNull(store.completeCacheLookup("wrong", true).cacheHit)
        assertEquals("download-busy", store.resolve("s2", "a.txt", "r2", true, true).snapshot.lastError)
        assertNotNull(store.completeCacheLookup("r1", true).cacheHit)
    }

    @Test
    fun sizeChangedBeforeTransferIsNotCachedAndExplicitDownloadsSkipCache() {
        val store = SharedWorkspaceFileStore()
        resolve(store)
        store.completeCacheLookup("r1", false)
        opened(store, 0)
        val result = store.acceptFrame("""{"kind":"file-download-chunk","transferId":"t1","offset":0,"data":"","eof":true,"sha256":"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"}""")
        assertNotNull(result.completion)
        assertNull(result.completion.modifiedAt)
        assertEquals("file-download-open", store.download("s1", "a.txt", "d1", "download").request?.requestType)
    }

    private fun resolve(store: SharedWorkspaceFileStore) = run {
        store.resolve("s1", "/work/a.txt", "r1", true, true)
        store.acceptFrame(resolved("r1"))
    }
    private fun resolved(request: String, version: String = "10.5") =
        """{"kind":"file-resolved","requestId":"$request","sessionId":"s1","path":"a.txt","name":"a.txt","size":5,"modifiedAt":$version}"""
    private fun opened(store: SharedWorkspaceFileStore, size: Long = 5) = store.acceptFrame(
        """{"kind":"file-download-opened","requestId":"r1-download","transferId":"t1","sessionId":"s1","path":"a.txt","name":"a.txt","size":$size,"chunkBytes":100}""")
    private fun eof(store: SharedWorkspaceFileStore) = store.acceptFrame(
        """{"kind":"file-download-chunk","transferId":"t1","offset":0,"data":"aGVsbG8=","eof":true,"sha256":"$HASH"}""")

    companion object {
        const val HASH = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
    }
}
