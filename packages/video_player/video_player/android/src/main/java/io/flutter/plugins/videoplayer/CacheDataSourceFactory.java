package io.flutter.plugins.videoplayer;

import android.content.Context;
import com.google.android.exoplayer2.upstream.DataSource;
import com.google.android.exoplayer2.upstream.DefaultBandwidthMeter;
import com.google.android.exoplayer2.upstream.DefaultDataSourceFactory;
import com.google.android.exoplayer2.upstream.DefaultHttpDataSource;
import com.google.android.exoplayer2.upstream.DefaultHttpDataSourceFactory;
import com.google.android.exoplayer2.upstream.FileDataSource;
import com.google.android.exoplayer2.upstream.cache.CacheDataSink;
import com.google.android.exoplayer2.upstream.cache.CacheDataSource;
import com.google.android.exoplayer2.upstream.cache.SimpleCache;
import com.google.android.exoplayer2.util.Util;

class CacheDataSourceFactory implements DataSource.Factory {

  private static final long _1_MB = 1024 * 1024;
  private static final long _1_GB = 1024 * 1024;
  public static final long MAX_CACHE_SIZE = 400 * _1_MB;
  public static final long MAX_FILE_SIZE = 100 * _1_MB;

  private final Context context;
  private final DefaultDataSourceFactory defaultDatasourceFactory;
  private final SimpleCache simpleCache;
  private final long maxFileSize;

  CacheDataSourceFactory(Context context, SimpleCache simpleCache, long maxFileSize) {
    super();
    this.context = context;
    this.simpleCache = simpleCache;
    this.maxFileSize = maxFileSize;

    String userAgent = Util.getUserAgent(context, "ExoPlayer");
    DefaultBandwidthMeter bandwidthMeter = new DefaultBandwidthMeter.Builder(context).build();
    defaultDatasourceFactory =
        new DefaultDataSourceFactory(
            this.context,
            bandwidthMeter,
            new DefaultHttpDataSourceFactory(
                userAgent,
                bandwidthMeter,
                DefaultHttpDataSource.DEFAULT_CONNECT_TIMEOUT_MILLIS,
                DefaultHttpDataSource.DEFAULT_READ_TIMEOUT_MILLIS,
                true));
  }

  @Override
  public DataSource createDataSource() {
    return new CacheDataSource(
        simpleCache,
        defaultDatasourceFactory.createDataSource(),
        new FileDataSource(),
        new CacheDataSink(simpleCache, maxFileSize),
        CacheDataSource.FLAG_BLOCK_ON_CACHE | CacheDataSource.FLAG_IGNORE_CACHE_ON_ERROR,
        null);
  }
}
