package com.twilio.twilio_voice.utils

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.util.Log
import java.io.File
import java.io.FileOutputStream
import java.io.InputStream
import java.net.URL

class ImageUtils {

    companion object {
        val TAG: String = "ImageUtils"

        /**
         * Download and store image to cache (as png)
         * @param ctx Context Application context
         * @param url String URL to the image
         * @param filename String Filename to store the image as
         * @param folder String (default: "images")
         * @return Uri? Uri to the image in the cache, or null if there was an error
         */
//         * @param extension String (default: "png") Extension to store the image as
        fun saveToCache(
            ctx: Context,
            url: String,
            filename: String,
//            extension: String = "png",
            folder: String = "images"
        ): Uri? {
            val imageUrl = URL(url)
            try {
                val inputStream: InputStream = imageUrl.openStream()
                val bitmap = BitmapFactory.decodeStream(inputStream)
                if (bitmap == null) {
                    Log.d(TAG, "downloadAndStoreImage: bitmap is null for url: $url")
                    return null
                }

                val cachePath = File(ctx.cacheDir, folder)
                if (!cachePath.isDirectory) {
                    // make directories, mkdirs will return false if the directory already exists so we check for that first.
                    if (!cachePath.mkdirs()) {
                        Log.w(TAG, "downloadAndStoreImage: Failed to create mkdirs for cachePath: $cachePath");
                        return null
                    }
                }

                val path = StringBuilder().apply {
                    append(cachePath)
                    append("/")
                    append(filename)
                    append(".")
                    append("png")
//                        append(extension)
                }.toString()

                val file = File(path)
                val fileOutStream = FileOutputStream(file)
                if (!bitmap.compress(Bitmap.CompressFormat.PNG, 100, fileOutStream)) {
                    Log.w(TAG, "downloadAndStoreImage: Failed to compress bitmap to file: $file");
                    return null
                }

                fileOutStream.flush()
                fileOutStream.close()

                return Uri.fromFile(file)
            } catch (e: Exception) {
                Log.e(TAG, "downloadAndStoreImage: exception occurred getting image from url: $url")
                e.printStackTrace()
                return null
            }
        }
    }
}