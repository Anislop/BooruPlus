/*
 * Copyright 2017 Kodehawa
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 */

package net.kodehawa.lib.imageboards.boards;

/**
 * Direct HTTPS Moebooru endpoints used by the Android client.
 *
 * The .com endpoint is the full-content primary. The .net endpoint is only
 * used by the client as a bounded safe-mode fallback when .com is unavailable.
 */
public final class KonachanBoard extends CustomBoard {
    public static final KonachanBoard COM = new KonachanBoard("konachan.com");
    public static final KonachanBoard NET = new KonachanBoard("konachan.net");

    private KonachanBoard(String host) {
        super("https", host, "post.json", null, "page", null);
    }
}
