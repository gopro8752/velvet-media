package tv.velvet.data.streams;

import androidx.media3.common.C;
import androidx.media3.datasource.HttpDataSource;
import androidx.media3.exoplayer.source.LoadEventInfo;
import androidx.media3.exoplayer.source.MediaLoadData;
import androidx.media3.exoplayer.upstream.LoadErrorHandlingPolicy;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.Collections;

/** Real Media3 error objects. Unused URI metadata is null so no Android runtime is required. */
final class StreamPolicyFixtures {
    static IOException http(int status, String code, String body) {
        return new HttpDataSource.InvalidResponseCodeException(status, "Test response", null,
            code == null ? Collections.emptyMap() : Collections.singletonMap("x-velvet-stream-error", Collections.singletonList(code)),
            null, body.getBytes(StandardCharsets.UTF_8));
    }
    static LoadErrorHandlingPolicy.LoadErrorInfo info(IOException error, int count) {
        return new LoadErrorHandlingPolicy.LoadErrorInfo(
            new LoadEventInfo(1, null, null, Collections.emptyMap(), 1000, 100, 128),
            new MediaLoadData(C.DATA_TYPE_MEDIA), error, count);
    }
}
