/*
 * Copyright (c) 2023-2026, Tim Flynn <trflynn89@ladybird.org>
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include <AK/Enumerate.h>
#include <LibWebView/Application.h>
#include <LibWebView/SessionStore.h>

#import <Application/Application.h>
#import <Application/ApplicationDelegate.h>
#import <Interface/InfoBar.h>
#import <Interface/LadybirdWebView.h>
#import <Interface/Menu.h>
#import <Interface/Tab.h>
#import <Interface/TabController.h>
#import <Utilities/Conversions.h>

#if !__has_feature(objc_arc)
#    error "This project requires ARC"
#endif

@interface ApplicationDelegate ()

@property (nonatomic, strong) NSMutableArray<TabController*>* managed_tabs;
@property (nonatomic, weak) Tab* active_tab;

@property (nonatomic, strong) NSMenu* bookmarks_menu;

@property (nonatomic, strong) InfoBar* info_bar;

- (NSMenuItem*)createApplicationMenu;
- (NSMenuItem*)createFileMenu;
- (NSMenuItem*)createEditMenu;
- (NSMenuItem*)createViewMenu;
- (NSMenuItem*)createHistoryMenu;
- (NSMenuItem*)createBookmarksMenu;
- (NSMenuItem*)createInspectMenu;
- (NSMenuItem*)createDebugMenu;
- (NSMenuItem*)createWindowMenu;
- (NSMenuItem*)createHelpMenu;

@end

@implementation ApplicationDelegate

- (instancetype)init
{
    if (self = [super init]) {
        [NSApp setMainMenu:[[NSMenu alloc] init]];

        [[NSApp mainMenu] addItem:[self createApplicationMenu]];
        [[NSApp mainMenu] addItem:[self createFileMenu]];
        [[NSApp mainMenu] addItem:[self createEditMenu]];
        [[NSApp mainMenu] addItem:[self createViewMenu]];
        [[NSApp mainMenu] addItem:[self createHistoryMenu]];
        [[NSApp mainMenu] addItem:[self createBookmarksMenu]];
        [[NSApp mainMenu] addItem:[self createInspectMenu]];
        [[NSApp mainMenu] addItem:[self createDebugMenu]];
        [[NSApp mainMenu] addItem:[self createWindowMenu]];
        [[NSApp mainMenu] addItem:[self createHelpMenu]];

        self.managed_tabs = [[NSMutableArray alloc] init];

        // Reduce the tooltip delay, as the default delay feels quite long.
        [[NSUserDefaults standardUserDefaults] setObject:@100 forKey:@"NSInitialToolTipDelay"];
    }

    return self;
}

#pragma mark - Public methods

- (nonnull TabController*)createNewTab:(Web::HTML::ActivateTab)activate_tab
                               fromTab:(nullable Tab*)tab
{
    auto* controller = [[TabController alloc] init];
    [self initializeTabController:controller
                      activateTab:activate_tab
                          fromTab:tab];

    return controller;
}

- (TabController*)createNewTab:(Optional<URL::URL> const&)url
                       fromTab:(Tab*)tab
                   activateTab:(Web::HTML::ActivateTab)activate_tab
                   tabLocation:(TabLocation)tab_location
{
    auto* controller = [[TabController alloc] init];
    [self initializeTabController:controller
                      activateTab:activate_tab
                          fromTab:tab
                      tabLocation:tab_location];

    if (url.has_value()) {
        [controller loadURL:*url];

        if (*url != WebView::Application::settings().new_tab_page_url())
            [controller focusWebView];
    }

    return controller;
}

- (nonnull TabController*)createChildTab:(Optional<URL::URL> const&)url
                                 fromTab:(nonnull Tab*)tab
                             activateTab:(Web::HTML::ActivateTab)activate_tab
                               pageIndex:(u64)page_index
{
    auto* controller = [self createChildTab:activate_tab fromTab:tab pageIndex:page_index];

    if (url.has_value()) {
        [controller loadURL:*url];
    }

    [controller focusWebView];

    return controller;
}

- (void)setActiveTab:(Tab*)tab
{
    if (tab == self.activeTab)
        return;

    self.active_tab = tab;

    if (self.info_bar) {
        [self.info_bar tabBecameActive:self.active_tab];
    }

    WebView::Application::the().update_bookmark_action_for_current_web_view();
}

- (Tab*)activeTab
{
    return self.active_tab;
}

- (void)removeTab:(TabController*)controller
{
    [self.managed_tabs removeObject:controller];
    WebView::Application::the().schedule_session_persist();
}

- (NSUInteger)tabCount
{
    return self.managed_tabs.count;
}

- (void)rebuildBookmarksMenu
{
    Ladybird::repopulate_application_menu(self.bookmarks_menu, WebView::Application::the().bookmarks_menu());

    for (TabController* controller in self.managed_tabs) {
        auto* tab = (Tab*)[controller window];
        [tab rebuildBookmarksBar];
    }
}

- (void)onDevtoolsEnabled
{
    if (!self.info_bar) {
        self.info_bar = [[InfoBar alloc] init];
    }

    auto message = MUST(String::formatted("DevTools is enabled on port {}", WebView::Application::browser_options().devtools_port));

    [self.info_bar showWithMessage:Ladybird::string_to_ns_string(message)
                dismissButtonTitle:@"Disable"
              dismissButtonClicked:^{
                  MUST(WebView::Application::the().toggle_devtools_enabled());
              }
                         activeTab:self.active_tab];
}

- (void)onDevtoolsDisabled
{
    if (self.info_bar) {
        [self.info_bar hide];
        self.info_bar = nil;
    }
}

#pragma mark - Private methods

- (void)openLocation:(id)sender
{
    auto* current_tab = [NSApp keyWindow];

    if (![current_tab isKindOfClass:[Tab class]]) {
        return;
    }

    auto* controller = (TabController*)[current_tab windowController];
    [controller focusLocationToolbarItem];
}

- (void)createNewWindow:(id)sender
{
    [self createNewTab:WebView::Application::settings().new_tab_page_url()
               fromTab:nil
           activateTab:Web::HTML::ActivateTab::Yes
           tabLocation:TabLocation::end()];
}

- (nonnull TabController*)createChildTab:(Web::HTML::ActivateTab)activate_tab
                                 fromTab:(nonnull Tab*)tab
                               pageIndex:(u64)page_index
{
    auto* controller = [[TabController alloc] initAsChild:tab pageIndex:page_index];
    [self initializeTabController:controller
                      activateTab:activate_tab
                          fromTab:tab];

    return controller;
}

- (void)initializeTabController:(TabController*)controller
                    activateTab:(Web::HTML::ActivateTab)activate_tab
                        fromTab:(nullable Tab*)tab
{
    [self initializeTabController:controller
                      activateTab:activate_tab
                          fromTab:tab
                      tabLocation:TabLocation::end()];
}

- (void)initializeTabController:(TabController*)controller
                    activateTab:(Web::HTML::ActivateTab)activate_tab
                        fromTab:(nullable Tab*)tab
                    tabLocation:(TabLocation)tab_location
{
    Optional<NSUInteger> insertion_index;
    NSWindowTabGroup* tab_group = nil;

    auto* tab_for_location = tab_location.is_after_tab() ? tab_location.tab() : tab;
    if (tab_for_location) {
        tab_group = [tab_for_location tabGroup];

        if (tab_location.is_after_tab()) {
            auto* windows = [tab_group windows];
            auto tab_index = [windows indexOfObject:tab_for_location];
            if (tab_index != NSNotFound)
                insertion_index = tab_index + 1;
        }
    }

    [controller showWindow:nil];

    if (tab_for_location) {
        if (insertion_index.has_value())
            [tab_group insertWindow:controller.window atIndex:insertion_index.value()];
        else
            [tab_group addWindow:controller.window];

        // FIXME: Can we create the tabbed window above without it becoming active in the first place?
        if (activate_tab == Web::HTML::ActivateTab::No) {
            [tab_for_location orderFront:nil];
        }
    }

    if (activate_tab == Web::HTML::ActivateTab::Yes) {
        [[controller window] orderFrontRegardless];
        [controller focusLocationToolbarItem];
    }

    [self.managed_tabs addObject:controller];
    WebView::Application::the().schedule_session_persist();
}

- (void)closeCurrentTab:(id)sender
{
    auto* current_window = [NSApp keyWindow];
    [current_window performClose:self];
}

- (NSMenuItem*)createApplicationMenu
{
    auto* menu = [[NSMenuItem alloc] init];

    auto* process_name = [[NSProcessInfo processInfo] processName];
    auto* submenu = [[NSMenu alloc] initWithTitle:process_name];

    [submenu addItem:Ladybird::create_application_menu_item(WebView::Application::the().open_about_page_action())];
    [submenu addItem:[NSMenuItem separatorItem]];

    [submenu addItem:Ladybird::create_application_menu_item(WebView::Application::the().open_settings_page_action())];
    [submenu addItem:[NSMenuItem separatorItem]];

    [submenu addItem:[[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"Hide %@", process_name]
                                                action:@selector(hide:)
                                         keyEquivalent:@"h"]];
    [submenu addItem:[NSMenuItem separatorItem]];

    [submenu addItem:[[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"Quit %@", process_name]
                                                action:@selector(terminate:)
                                         keyEquivalent:@"q"]];

    [menu setSubmenu:submenu];
    return menu;
}

- (NSMenuItem*)createFileMenu
{
    auto* menu = [[NSMenuItem alloc] init];
    auto* submenu = [[NSMenu alloc] initWithTitle:@"File"];

    [submenu addItem:[[NSMenuItem alloc] initWithTitle:@"New Window"
                                                action:@selector(createNewWindow:)
                                         keyEquivalent:@"n"]];
    [submenu addItem:[[NSMenuItem alloc] initWithTitle:@"New Tab"
                                                action:@selector(createNewTab:)
                                         keyEquivalent:@"t"]];
    [submenu addItem:[[NSMenuItem alloc] initWithTitle:@"Close Tab"
                                                action:@selector(closeCurrentTab:)
                                         keyEquivalent:@"w"]];
    [submenu addItem:[NSMenuItem separatorItem]];

    [submenu addItem:Ladybird::create_application_menu_item(WebView::Application::the().open_downloads_page_action())];
    [submenu addItem:[[NSMenuItem alloc] initWithTitle:@"Open Location"
                                                action:@selector(openLocation:)
                                         keyEquivalent:@"l"]];

    [menu setSubmenu:submenu];
    return menu;
}

- (NSMenuItem*)createEditMenu
{
    auto* menu = [[NSMenuItem alloc] init];
    auto* submenu = [[NSMenu alloc] initWithTitle:@"Edit"];

    [submenu addItem:[[NSMenuItem alloc] initWithTitle:@"Undo"
                                                action:@selector(undo:)
                                         keyEquivalent:@"z"]];
    [submenu addItem:[[NSMenuItem alloc] initWithTitle:@"Redo"
                                                action:@selector(redo:)
                                         keyEquivalent:@"y"]];
    [submenu addItem:[NSMenuItem separatorItem]];

    [submenu addItem:Ladybird::create_application_menu_item(WebView::Application::the().cut_selection_action())];
    [submenu addItem:Ladybird::create_application_menu_item(WebView::Application::the().copy_selection_action())];
    [submenu addItem:Ladybird::create_application_menu_item(WebView::Application::the().paste_action())];
    [submenu addItem:[NSMenuItem separatorItem]];

    [submenu addItem:Ladybird::create_application_menu_item(WebView::Application::the().select_all_action())];
    [submenu addItem:[NSMenuItem separatorItem]];

    [submenu addItem:[[NSMenuItem alloc] initWithTitle:@"Find..."
                                                action:@selector(find:)
                                         keyEquivalent:@"f"]];
    [submenu addItem:[[NSMenuItem alloc] initWithTitle:@"Find Next"
                                                action:@selector(findNextMatch:)
                                         keyEquivalent:@"g"]];
    [submenu addItem:[[NSMenuItem alloc] initWithTitle:@"Find Previous"
                                                action:@selector(findPreviousMatch:)
                                         keyEquivalent:@"G"]];
    [submenu addItem:[[NSMenuItem alloc] initWithTitle:@"Use Selection for Find"
                                                action:@selector(useSelectionForFind:)
                                         keyEquivalent:@"e"]];

    [menu setSubmenu:submenu];
    return menu;
}

- (NSMenuItem*)createViewMenu
{
    auto* menu = [[NSMenuItem alloc] init];
    auto* submenu = [[NSMenu alloc] initWithTitle:@"View"];

    [submenu addItem:Ladybird::create_application_menu_item(WebView::Application::the().reload_action())];
    [submenu addItem:[NSMenuItem separatorItem]];

    [submenu addItem:Ladybird::create_application_menu_item(WebView::Application::the().zoom_menu())];
    [submenu addItem:[NSMenuItem separatorItem]];
    [submenu addItem:Ladybird::create_application_menu_item(WebView::Application::the().color_scheme_menu())];
    [submenu addItem:Ladybird::create_application_menu_item(WebView::Application::the().contrast_menu())];
    [submenu addItem:Ladybird::create_application_menu_item(WebView::Application::the().motion_menu())];
    [submenu addItem:[NSMenuItem separatorItem]];

    [menu setSubmenu:submenu];
    return menu;
}

- (NSMenuItem*)createHistoryMenu
{
    return Ladybird::create_application_menu_item(WebView::Application::the().history_menu());
}

- (NSMenuItem*)createBookmarksMenu
{
    auto* menu = Ladybird::create_application_menu_item(WebView::Application::the().bookmarks_menu());
    self.bookmarks_menu = [menu submenu];
    return menu;
}

- (NSMenuItem*)createInspectMenu
{
    return Ladybird::create_application_menu_item(WebView::Application::the().inspect_menu());
}

- (NSMenuItem*)createDebugMenu
{
    return Ladybird::create_application_menu_item(WebView::Application::the().debug_menu());
}

- (NSMenuItem*)createWindowMenu
{
    auto* menu = [[NSMenuItem alloc] init];
    auto* submenu = [[NSMenu alloc] initWithTitle:@"Window"];

    [NSApp setWindowsMenu:submenu];

    [menu setSubmenu:submenu];
    return menu;
}

- (NSMenuItem*)createHelpMenu
{
    auto* menu = [[NSMenuItem alloc] init];
    auto* submenu = [[NSMenu alloc] initWithTitle:@"Help"];

    [NSApp setHelpMenu:submenu];

    [menu setSubmenu:submenu];
    return menu;
}

- (WebView::SessionSnapshot)captureSession
{
    WebView::SessionSnapshot snapshot;
    NSMutableSet* seen_tab_groups = [NSMutableSet set];

    for (TabController* controller in self.managed_tabs) {
        auto* tab = (Tab*)[controller window];
        if (tab == nil || ![tab isVisible])
            continue;

        NSWindowTabGroup* tab_group = [tab tabGroup];
        if (tab_group != nil) {
            if ([seen_tab_groups containsObject:tab_group])
                continue;
            [seen_tab_groups addObject:tab_group];
        }

        WebView::SessionWindow session_window;
        NSArray<NSWindow*>* windows = tab_group != nil ? [tab_group windows] : @[ tab ];
        NSWindow* selected_window = tab_group != nil ? [tab_group selectedWindow] : tab;
        size_t index = 0;

        for (NSWindow* window in windows) {
            if (![window isKindOfClass:[Tab class]])
                continue;

            auto* session_tab = (Tab*)window;
            session_window.tabs.append(WebView::SessionTab { [[session_tab web_view] view].url() });
            if (window == selected_window)
                session_window.active_tab_index = index;
            ++index;
        }

        if (session_window.tabs.is_empty())
            continue;

        auto frame = NSIntegralRect([tab frame]);
        session_window.x = static_cast<i32>(frame.origin.x);
        session_window.y = static_cast<i32>(frame.origin.y);
        session_window.width = static_cast<i32>(frame.size.width);
        session_window.height = static_cast<i32>(frame.size.height);
        session_window.maximized = [tab isZoomed];
        snapshot.windows.append(move(session_window));
    }

    return snapshot;
}

- (void)restoreSession:(WebView::SessionSnapshot const&)session
{
    for (auto const& window_state : session.windows) {
        Tab* first_tab = nil;

        for (auto const& [i, tab_state] : enumerate(window_state.tabs)) {
            auto activate_tab = i == window_state.active_tab_index ? Web::HTML::ActivateTab::Yes : Web::HTML::ActivateTab::No;
            auto* controller = [self createNewTab:tab_state.url
                                          fromTab:first_tab
                                      activateTab:activate_tab
                                      tabLocation:TabLocation::end()];
            auto* tab = (Tab*)[controller window];
            if (first_tab == nil) {
                first_tab = tab;
                if (window_state.width.has_value() && window_state.height.has_value()) {
                    auto frame = [tab frame];
                    if (window_state.x.has_value())
                        frame.origin.x = *window_state.x;
                    if (window_state.y.has_value())
                        frame.origin.y = *window_state.y;
                    frame.size.width = *window_state.width;
                    frame.size.height = *window_state.height;
                    [tab setFrame:frame display:YES];
                }
                if (window_state.maximized && ![tab isZoomed])
                    [tab zoom:nil];
            }
        }
    }
}

#pragma mark - NSApplicationDelegate

- (void)applicationDidFinishLaunching:(NSNotification*)notification
{
    auto const& browser_options = WebView::Application::browser_options();

    if (browser_options.devtools_port.has_value())
        [self onDevtoolsEnabled];

    if (auto session = WebView::Application::the().session_to_restore_on_startup(); session.has_value()) {
        [self restoreSession:*session];
        return;
    }

    Tab* tab = nil;

    for (auto const& url : browser_options.urls) {
        auto activate_tab = tab == nil ? Web::HTML::ActivateTab::Yes : Web::HTML::ActivateTab::No;

        auto* controller = [self createNewTab:url
                                      fromTab:tab
                                  activateTab:activate_tab
                                  tabLocation:TabLocation::end()];

        tab = (Tab*)[controller window];
    }
}

- (void)applicationWillTerminate:(NSNotification*)notification
{
    WebView::Application::the().persist_session_now();
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication*)sender
{
    return [(Application*)sender confirmCancelActiveDownloads];
}

- (void)applicationDidChangeScreenParameters:(NSNotification*)notification
{
    for (TabController* controller in self.managed_tabs) {
        auto* tab = (Tab*)[controller window];
        [[tab web_view] handleDisplayRefreshRateChange];
    }
}

- (BOOL)validateMenuItem:(NSMenuItem*)menu
{
    SEL action = [menu action];

    if (action == @selector(closeCurrentTab:)) {
        return [[NSApp keyWindow] isKindOfClass:[Tab class]];
    }

    return YES;
}

@end
