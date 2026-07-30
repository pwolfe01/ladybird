/*
 * Copyright (c) 2026, Pat Wolfe <pat@graphite.dev>
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include <AK/JsonValue.h>
#include <AK/ScopeGuard.h>
#include <LibCore/Directory.h>
#include <LibCore/StandardPaths.h>
#include <LibFileSystem/FileSystem.h>
#include <LibTest/TestCase.h>
#include <LibURL/Parser.h>
#include <LibWebView/SessionStore.h>
#include <LibWebView/Utilities.h>

static URL::URL parse_url(StringView url)
{
    auto parsed_url = URL::Parser::basic_parse(url);
    VERIFY(parsed_url.has_value());
    return parsed_url.release_value();
}

static ByteString unique_session_path()
{
    static u64 next_id = 0;
    auto directory = ByteString::formatted("{}/ladybird-session-tests", Core::StandardPaths::tempfile_directory());
    MUST(Core::Directory::create(directory, Core::Directory::CreateDirectories::Yes));
    return ByteString::formatted("{}/session-{}.json", directory, ++next_id);
}

TEST_CASE(empty_snapshot_is_empty)
{
    WebView::SessionSnapshot snapshot;
    EXPECT(snapshot.is_empty());

    snapshot.windows.append(WebView::SessionWindow {});
    EXPECT(snapshot.is_empty());

    snapshot.windows.last().tabs.append({ parse_url("https://example.com/"sv) });
    EXPECT(!snapshot.is_empty());
}

TEST_CASE(roundtrip_persists_windows_and_tabs)
{
    auto path = unique_session_path();
    ScopeGuard remove_file = [&] {
        (void)FileSystem::remove(path, FileSystem::RecursionMode::Disallowed);
    };

    WebView::SessionSnapshot snapshot;
    snapshot.windows.append(WebView::SessionWindow {
        .tabs = {
            { parse_url("https://example.com/"sv) },
            { parse_url("https://ladybird.org/"sv) },
        },
        .active_tab_index = 1,
        .x = 12,
        .y = 34,
        .width = 800,
        .height = 600,
        .maximized = true,
    });
    snapshot.windows.append(WebView::SessionWindow {
        .tabs = { { parse_url("https://github.com/"sv) } },
        .active_tab_index = 0,
        .x = {},
        .y = {},
        .width = 1024,
        .height = 768,
        .maximized = false,
    });

    auto store = WebView::SessionStore::create_for_path(path);
    store.save(snapshot);

    auto loaded = store.load();
    VERIFY(loaded.windows.size() == 2);

    EXPECT_EQ(loaded.windows[0].tabs.size(), 2u);
    EXPECT_EQ(loaded.windows[0].tabs[0].url.serialize(), "https://example.com/"_string);
    EXPECT_EQ(loaded.windows[0].tabs[1].url.serialize(), "https://ladybird.org/"_string);
    EXPECT_EQ(loaded.windows[0].active_tab_index, 1u);
    EXPECT(loaded.windows[0].x.has_value());
    EXPECT_EQ(*loaded.windows[0].x, 12);
    EXPECT(loaded.windows[0].y.has_value());
    EXPECT_EQ(*loaded.windows[0].y, 34);
    EXPECT(loaded.windows[0].width.has_value());
    EXPECT_EQ(*loaded.windows[0].width, 800);
    EXPECT(loaded.windows[0].height.has_value());
    EXPECT_EQ(*loaded.windows[0].height, 600);
    EXPECT(loaded.windows[0].maximized);

    EXPECT_EQ(loaded.windows[1].tabs.size(), 1u);
    EXPECT_EQ(loaded.windows[1].tabs[0].url.serialize(), "https://github.com/"_string);
    EXPECT(loaded.windows[1].width.has_value());
    EXPECT_EQ(*loaded.windows[1].width, 1024);
    EXPECT(loaded.windows[1].height.has_value());
    EXPECT_EQ(*loaded.windows[1].height, 768);
    EXPECT(!loaded.windows[1].maximized);
}

TEST_CASE(clear_writes_empty_session)
{
    auto path = unique_session_path();
    ScopeGuard remove_file = [&] {
        (void)FileSystem::remove(path, FileSystem::RecursionMode::Disallowed);
    };

    auto store = WebView::SessionStore::create_for_path(path);
    store.save(WebView::SessionSnapshot {
        .windows = { {
            .tabs = { { parse_url("https://example.com/"sv) } },
        } },
    });
    EXPECT(!store.load().is_empty());

    store.clear();
    EXPECT(store.load().is_empty());
}

TEST_CASE(missing_file_loads_empty_session)
{
    auto store = WebView::SessionStore::create_for_path("/tmp/ladybird-session-does-not-exist.json");
    EXPECT(store.load().is_empty());
}

TEST_CASE(invalid_urls_and_windows_are_skipped)
{
    auto path = unique_session_path();
    ScopeGuard remove_file = [&] {
        (void)FileSystem::remove(path, FileSystem::RecursionMode::Disallowed);
    };

    MUST(WebView::write_json_file(path, MUST(JsonValue::from_string(R"JSON({
        "version": 1,
        "windows": [
            { "tabs": [{ "url": "not a url" }] },
            { "tabs": [{ "url": "https://example.com/" }, { "url": "also not a url" }] },
            { "tabs": [] },
            "invalid"
        ]
    })JSON"_string))));

    auto store = WebView::SessionStore::create_for_path(path);
    auto loaded = store.load();
    VERIFY(loaded.windows.size() == 1);
    EXPECT_EQ(loaded.windows[0].tabs.size(), 1u);
    EXPECT_EQ(loaded.windows[0].tabs[0].url.serialize(), "https://example.com/"_string);
}

TEST_CASE(unsupported_version_is_ignored)
{
    auto path = unique_session_path();
    ScopeGuard remove_file = [&] {
        (void)FileSystem::remove(path, FileSystem::RecursionMode::Disallowed);
    };

    MUST(WebView::write_json_file(path, MUST(JsonValue::from_string(R"JSON({
        "version": 99,
        "windows": [{ "tabs": [{ "url": "https://example.com/" }] }]
    })JSON"_string))));

    auto store = WebView::SessionStore::create_for_path(path);
    EXPECT(store.load().is_empty());
}
