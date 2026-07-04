#!/usr/bin/env python
# License: GPL v3 Copyright: 2026, Kovid Goyal <kovid at kovidgoyal.net>

from unittest.mock import patch

from kitty.fast_data_types import Region
from kitty.tab_bar import TabBar, TabBarData

from . import BaseTest


def region(left: int, top: int, right: int, bottom: int) -> Region:
    return Region((left, top, right, bottom, right - left, bottom - top))


class DummyBoss:
    class mappings:
        current_keyboard_mode_name = ''

    def tab_for_id(self, tab_id: int) -> None:
        return None


class TestTabBar(BaseTest):

    def test_close_button_hit_testing(self) -> None:
        self.set_options({
            'tab_bar_style': 'separator',
            'tab_title_template': '{title}',
        })
        central = region(0, 20, 300, 120)
        tab_bar = region(0, 0, 300, 20)

        with (
            patch('kitty.tab_bar.cell_size_for_window', return_value=(10, 20)),
            patch('kitty.tab_bar.viewport_for_window', return_value=(central, tab_bar, 300, 120, 10, 20)),
            patch('kitty.tab_bar.set_tab_bar_render_data'),
            patch('kitty.tab_bar.get_boss', return_value=DummyBoss()),
        ):
            tb = TabBar(1)
            tb.layout()
            tb.update((
                TabBarData(title='first tab', tab_id=1, is_active=True),
                TabBarData(title='second tab', tab_id=2),
            ))

        self.assertGreaterEqual(len(tb.tab_extents), 2)
        first = tb.tab_extents[0]
        self.assertIsNotNone(first.close_button)
        assert first.close_button is not None
        close_x = tb.window_geometry.left + first.close_button.start * tb.cell_width
        tab_x = tb.window_geometry.left + first.cell_range.start * tb.cell_width
        self.ae(tb.tab_id_at(close_x), 1)
        self.ae(tb.close_button_tab_id_at(close_x), 1)
        self.ae(tb.close_button_tab_id_at(tab_x), 0)
