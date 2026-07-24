package com.booruplus.app

import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns
import java.io.File
import java.io.FileNotFoundException

/**
 * Serves media saved for the share sheet from the app's private
 * `cache/shared` folder, read-only. It is not exported: receiving apps read
 * a file only through the temporary grant on the share intent.
 */
class SharedMediaProvider : ContentProvider() {
    override fun onCreate(): Boolean = true

    private fun fileFor(uri: Uri): File? {
        val name = uri.lastPathSegment ?: return null
        if (uri.pathSegments.size != 1 || name.startsWith(".")) return null
        val context = context ?: return null
        val directory = File(context.cacheDir, DIRECTORY).canonicalFile
        val file = File(directory, name).canonicalFile
        return if (file.parentFile == directory && file.isFile) file else null
    }

    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor {
        if (mode != "r") throw SecurityException("Shared media is read-only")
        val file = fileFor(uri) ?: throw FileNotFoundException()
        return ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
    }

    override fun getType(uri: Uri): String? = fileFor(uri)?.let { mediaMimeType(it.name) }

    override fun query(
        uri: Uri,
        projection: Array<out String>?,
        selection: String?,
        selectionArgs: Array<out String>?,
        sortOrder: String?
    ): Cursor? {
        val file = fileFor(uri) ?: return null
        val columns = projection ?: arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE)
        return MatrixCursor(columns, 1).apply {
            addRow(columns.map { column ->
                when (column) {
                    OpenableColumns.DISPLAY_NAME -> file.name
                    OpenableColumns.SIZE -> file.length()
                    else -> null
                }
            })
        }
    }

    override fun insert(uri: Uri, values: ContentValues?): Uri? = throw UnsupportedOperationException()

    override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?): Int = 0

    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int = 0

    companion object {
        const val DIRECTORY = "shared"

        fun uriFor(context: Context, name: String): Uri = Uri.Builder()
            .scheme("content")
            .authority("${context.packageName}.shared")
            .appendPath(name)
            .build()
    }
}
