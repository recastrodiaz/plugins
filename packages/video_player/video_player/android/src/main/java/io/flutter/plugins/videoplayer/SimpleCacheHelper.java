package io.flutter.plugins.videoplayer;

import android.content.Context;
import com.google.android.exoplayer2.database.ExoDatabaseProvider;
import com.google.android.exoplayer2.upstream.cache.LeastRecentlyUsedCacheEvictor;
import com.google.android.exoplayer2.upstream.cache.SimpleCache;
import java.io.File;

public class SimpleCacheHelper {

  private static volatile SimpleCache INSTANCE = null;

  public static SimpleCache getInstance(File cacheDirectory, Context context) {
    if (INSTANCE == null) { // Check 1
      synchronized (SimpleCacheHelper.class) {
        if (INSTANCE == null) { // Check 2
          LeastRecentlyUsedCacheEvictor evictor =
              new LeastRecentlyUsedCacheEvictor(CacheDataSourceFactory.MAX_CACHE_SIZE);
          INSTANCE = new SimpleCache(cacheDirectory, evictor, new ExoDatabaseProvider(context));
        }
      }
    }
    return INSTANCE;
  }
}
