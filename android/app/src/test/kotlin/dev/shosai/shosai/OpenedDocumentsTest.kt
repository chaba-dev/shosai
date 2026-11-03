package dev.shosai.shosai

import android.content.ClipData
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28, 35])
class OpenedDocumentsTest {
    @Test
    fun `VIEW and SEND accept only granted file schemes and supported types`() {
        for (type in listOf("application/epub+zip", "application/pdf")) {
            for (uri in listOf(Uri.parse("content://books/42"), Uri.parse("file:///books/a.pdf"))) {
                assertEquals(uri, openedDocumentUri(Intent(Intent.ACTION_VIEW).setDataAndType(uri, type)))
                assertEquals(uri, openedDocumentUri(Intent(Intent.ACTION_SEND).setType(type)
                    .putExtra(Intent.EXTRA_STREAM, uri)))
                assertEquals(uri, openedDocumentUri(Intent(Intent.ACTION_SEND).setType(type)
                    .apply { clipData = ClipData.newRawUri("book", uri) }))
            }
        }
        for (uri in listOf("https://example.com/a.pdf", "data:application/pdf,abc")) {
            assertNull(openedDocumentUri(Intent(Intent.ACTION_VIEW)
                .setDataAndType(Uri.parse(uri), "application/pdf")))
        }
        assertNull(openedDocumentUri(Intent(Intent.ACTION_VIEW)
            .setDataAndType(Uri.parse("content://books/42"), "image/png")))
        assertNull(openedDocumentUri(Intent(Intent.ACTION_SEND_MULTIPLE).setType("application/pdf")))
        assertNull(openedDocumentUri(Intent(Intent.ACTION_SEND).setType("application/pdf")))
        assertNull(openedDocumentUri(Intent(Intent.ACTION_SEND).setType("application/pdf")
            .putExtra(Intent.EXTRA_STREAM, Bundle())))
    }
}
