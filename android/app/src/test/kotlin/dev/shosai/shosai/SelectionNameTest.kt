package dev.shosai.shosai

import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.provider.OpenableColumns
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28, 35])
class SelectionNameTest {
    /** Answers `DISPLAY_NAME` with the URI's `name` query parameter, like a documents provider. */
    class NamesProvider : ContentProvider() {
        override fun onCreate() = true

        override fun query(
            uri: Uri,
            projection: Array<String>?,
            selection: String?,
            selectionArgs: Array<String>?,
            sortOrder: String?,
        ): Cursor? {
            val name = uri.getQueryParameter("name") ?: return null
            return MatrixCursor(arrayOf(OpenableColumns.DISPLAY_NAME)).apply { addRow(arrayOf(name)) }
        }

        override fun getType(uri: Uri): String? = null
        override fun insert(uri: Uri, values: ContentValues?): Uri? = null
        override fun delete(uri: Uri, selection: String?, selectionArgs: Array<String>?) = 0
        override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<String>?) = 0
    }

    private val resolver by lazy {
        Robolectric.setupContentProvider(NamesProvider::class.java, "names")
        RuntimeEnvironment.getApplication().contentResolver
    }

    @Test
    fun `the provider's display name names a document with an opaque id`() {
        // Downloads exposes `msf:<id>` document IDs: the path says nothing about the file.
        assertEquals(
            "Deep Work.pdf",
            selectionName(resolver, Uri.parse("content://names/document/msf%3A1042?name=Deep%20Work.pdf"), 0),
        )
        assertEquals(
            "notes_v2.epub",
            selectionName(resolver, Uri.parse("content://names/document/msf%3A7?name=notes%2Fv2.epub"), 0),
        )
    }

    @Test
    fun `a display name without a supported extension yields to the path, then the placeholder`() {
        assertEquals(
            "shelf.epub",
            selectionName(resolver, Uri.parse("content://names/document/primary%3Ashelf.epub?name=shelf"), 0),
        )
        assertEquals(
            "Document 3",
            selectionName(resolver, Uri.parse("content://names/document/msf%3A9?name=shelf"), 2),
        )
    }

    @Test
    fun `a provider that cannot be queried leaves the path naming`() {
        assertEquals(
            "tree.epub",
            selectionName(resolver, Uri.parse("content://nobody/tree/primary%3ABooks%2Ftree.epub"), 0),
        )
        assertEquals("Document 1", selectionName(resolver, Uri.parse("content://nobody/document/msf%3A99"), 0))
        assertEquals("plain.pdf", selectionName(null, Uri.parse("file:///books/plain.pdf"), 0))
    }
}
