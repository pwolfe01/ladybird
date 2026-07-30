/*
 * Copyright (c) 2026, Pat Wolfe <pat@graphite.dev>
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include <AK/JsonArray.h>
#include <AK/JsonObject.h>
#include <LibCore/StandardPaths.h>
#include <LibURL/Parser.h>
#include <LibWebView/SessionStore.h>
#include <LibWebView/Utilities.h>

namespace WebView {

static constexpr auto VERSION_KEY = "version"sv;
static constexpr auto WINDOWS_KEY = "windows"sv;
static constexpr auto TABS_KEY = "tabs"sv;
static constexpr auto URL_KEY = "url"sv;
static constexpr auto ACTIVE_TAB_INDEX_KEY = "activeTabIndex"sv;
static constexpr auto X_KEY = "x"sv;
static constexpr auto Y_KEY = "y"sv;
static constexpr auto WIDTH_KEY = "width"sv;
static constexpr auto HEIGHT_KEY = "height"sv;
static constexpr auto MAXIMIZED_KEY = "maximized"sv;

static constexpr u32 CURRENT_VERSION = 1;

bool SessionSnapshot::is_empty() const
{
    for (auto const& window : windows) {
        if (!window.tabs.is_empty())
            return false;
    }
    return true;
}

static SessionSnapshot parse_snapshot(JsonObject const& root)
{
    SessionSnapshot snapshot;

    auto version = root.get_u32(VERSION_KEY).value_or(0);
    if (version != CURRENT_VERSION)
        return snapshot;

    auto windows = root.get_array(WINDOWS_KEY);
    if (!windows.has_value())
        return snapshot;

    windows->for_each([&](JsonValue const& window_value) {
        if (!window_value.is_object())
            return;

        auto const& window_object = window_value.as_object();
        auto tabs = window_object.get_array(TABS_KEY);
        if (!tabs.has_value())
            return;

        SessionWindow window;

        tabs->for_each([&](JsonValue const& tab_value) {
            if (!tab_value.is_object())
                return;

            auto url_string = tab_value.as_object().get_string(URL_KEY);
            if (!url_string.has_value())
                return;

            auto url = URL::Parser::basic_parse(*url_string);
            if (!url.has_value())
                return;

            window.tabs.append(SessionTab { url.release_value() });
        });

        if (window.tabs.is_empty())
            return;

        if (auto active_tab_index = window_object.get_u64(ACTIVE_TAB_INDEX_KEY); active_tab_index.has_value())
            window.active_tab_index = *active_tab_index < window.tabs.size() ? *active_tab_index : window.tabs.size() - 1;

        if (auto x = window_object.get_integer<i32>(X_KEY); x.has_value())
            window.x = *x;
        if (auto y = window_object.get_integer<i32>(Y_KEY); y.has_value())
            window.y = *y;
        if (auto width = window_object.get_integer<i32>(WIDTH_KEY); width.has_value())
            window.width = *width;
        if (auto height = window_object.get_integer<i32>(HEIGHT_KEY); height.has_value())
            window.height = *height;
        if (auto maximized = window_object.get_bool(MAXIMIZED_KEY); maximized.has_value())
            window.maximized = *maximized;

        snapshot.windows.append(move(window));
    });

    return snapshot;
}

static JsonObject serialize_snapshot(SessionSnapshot const& snapshot)
{
    JsonArray windows;
    windows.ensure_capacity(snapshot.windows.size());

    for (auto const& window : snapshot.windows) {
        if (window.tabs.is_empty())
            continue;

        JsonArray tabs;
        tabs.ensure_capacity(window.tabs.size());

        for (auto const& tab : window.tabs) {
            JsonObject tab_object;
            tab_object.set(URL_KEY, tab.url.serialize());
            tabs.must_append(move(tab_object));
        }

        JsonObject window_object;
        window_object.set(TABS_KEY, move(tabs));
        window_object.set(ACTIVE_TAB_INDEX_KEY, static_cast<u64>(window.active_tab_index));

        if (window.x.has_value())
            window_object.set(X_KEY, *window.x);
        if (window.y.has_value())
            window_object.set(Y_KEY, *window.y);
        if (window.width.has_value())
            window_object.set(WIDTH_KEY, *window.width);
        if (window.height.has_value())
            window_object.set(HEIGHT_KEY, *window.height);
        window_object.set(MAXIMIZED_KEY, window.maximized);

        windows.must_append(move(window_object));
    }

    JsonObject root;
    root.set(VERSION_KEY, CURRENT_VERSION);
    root.set(WINDOWS_KEY, move(windows));
    return root;
}

SessionStore SessionStore::create(Badge<Application>)
{
    auto session_directory = ByteString::formatted("{}/Ladybird", Core::StandardPaths::config_directory());
    return create_for_path(ByteString::formatted("{}/Session.json", session_directory));
}

SessionStore SessionStore::create_for_path(ByteString path)
{
    return SessionStore { move(path) };
}

SessionStore::SessionStore(ByteString path)
    : m_path(move(path))
{
}

SessionSnapshot SessionStore::load() const
{
    auto session_json = read_json_file(m_path);
    if (session_json.is_error()) {
        warnln("Unable to read Ladybird session: {}", session_json.error());
        return {};
    }

    return parse_snapshot(session_json.value());
}

void SessionStore::save(SessionSnapshot const& snapshot)
{
    if (auto result = write_json_file(m_path, serialize_snapshot(snapshot)); result.is_error())
        warnln("Unable to persist Ladybird session: {}", result.error());
}

void SessionStore::clear()
{
    save({});
}

}
