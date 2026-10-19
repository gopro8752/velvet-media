package tv.velvet.data.net

import kotlinx.coroutines.suspendCancellableCoroutine
import okhttp3.Call
import okhttp3.Callback
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import java.io.IOException
import kotlin.coroutines.resumeWithException

/**
 * Truly-cancellable OkHttp call: cancelling the coroutine cancels the socket (so a
 * timeout or a scrolled-away row releases its connection immediately), and a response
 * that loses the race against cancellation is closed instead of leaking its pooled
 * connection (the documented hazard the resume(value, onCancellation) overload exists for).
 */
internal suspend fun OkHttpClient.await(request: Request): Response =
    suspendCancellableCoroutine { continuation ->
        val call = newCall(request)
        continuation.invokeOnCancellation { call.cancel() }
        call.enqueue(object : Callback {
            override fun onFailure(call: Call, e: IOException) {
                // Resuming a cancelled continuation is a no-op, so this is race-free.
                continuation.resumeWithException(e)
            }

            override fun onResponse(call: Call, response: Response) {
                continuation.resume(response) { _, _, _ -> response.close() }
            }
        })
    }
