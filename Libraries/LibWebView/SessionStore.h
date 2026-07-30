/*
 * Copyright (c) 2026, Pat Wolfe <pat@graphite.dev>
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#pragma once

#include <AK/Badge.h>
#include <AK/ByteString.h>
#include <AK/Optional.h>
#include <AK/Vector.h>
#include <LibURL/URL.h>
#include <LibWebView/Export.h>
#include <LibWebView/Forward.h>

namespace WebView {

struct WEBVIEW_API SessionTab {
    URL::URL url;
};

struct WEBVIEW_API SessionWindow {
    Vector<SessionTab> tabs;
    size_t active_tab_index { 0 };
    Optional<i32> x;
    Optional<i32> y;
    Optional<i32> width;
    Optional<i32> height;
    bool maximized { false };
};

struct WEBVIEW_API SessionSnapshot {
    Vector<SessionWindow> windows;

    bool is_empty() const;
};

class WEBVIEW_API SessionStore {
public:
    static SessionStore create(Badge<Application>);
    static SessionStore create_for_path(ByteString path);

    SessionSnapshot load() const;
    void save(SessionSnapshot const&);
    void clear();

private:
    explicit SessionStore(ByteString path);

    ByteString m_path;
};

}
