from pathlib import Path


def patch_once(text: str, marker: str, anchor: str, insert: str) -> str:
    if marker in text:
        return text
    if anchor not in text:
        raise RuntimeError(f"Anchor not found: {anchor}")
    return text.replace(anchor, insert + anchor, 1)


runner_main = Path("linux/runner/main.cc")
app_source = Path("linux/runner/my_application.cc")

if not runner_main.exists():
    raise RuntimeError(f"Missing generated Linux runner file: {runner_main}")
if not app_source.exists():
    raise RuntimeError(f"Missing generated Linux runner file: {app_source}")

main_text = runner_main.read_text(encoding="utf-8")
main_marker = "Sena Repo Linux input compatibility"
main_insert = """  // Sena Repo Linux input compatibility.
  // Prefer native Wayland on Bazzite/Gamescope, with X11 as fallback.
  g_setenv("GDK_BACKEND", "wayland,x11", TRUE);
  g_setenv("GDK_TOUCH", "1", TRUE);
  g_setenv("GTK_TEST_TOUCHSCREEN", "1", TRUE);
  g_printerr("Sena Linux input backend preference: %s\\n", g_getenv("GDK_BACKEND"));
"""
main_text = patch_once(
    main_text,
    main_marker,
    "  g_autoptr(MyApplication) app = my_application_new();",
    main_insert,
)
runner_main.write_text(main_text, encoding="utf-8")

app_text = app_source.read_text(encoding="utf-8")
helper_marker = "sena_enable_touch_events"
helper_code = r"""
// Sena Repo touch compatibility and diagnostics for GTK/Flutter Linux.
static const char* sena_touch_event_name(GdkEventType type) {
  switch (type) {
    case GDK_TOUCH_BEGIN:
      return "begin";
    case GDK_TOUCH_UPDATE:
      return "update";
    case GDK_TOUCH_END:
      return "end";
    case GDK_TOUCH_CANCEL:
      return "cancel";
    default:
      return "other";
  }
}

static gboolean sena_touch_event_probe(GtkWidget* widget,
                                       GdkEvent* event,
                                       gpointer user_data) {
  GdkEventType type = gdk_event_get_event_type(event);
  if (type != GDK_TOUCH_BEGIN && type != GDK_TOUCH_UPDATE &&
      type != GDK_TOUCH_END && type != GDK_TOUCH_CANCEL) {
    return FALSE;
  }

  static int logged_events = 0;
  if (logged_events < 32) {
    GdkEventTouch* touch = reinterpret_cast<GdkEventTouch*>(event);
    const gchar* widget_name = gtk_widget_get_name(widget);
    GdkDisplay* display = gdk_display_get_default();
    g_printerr("Sena Linux touch event: %s x=%.1f y=%.1f widget=%s backend=%s\n",
               sena_touch_event_name(type), touch->x, touch->y,
               widget_name != nullptr ? widget_name : "unknown",
               display != nullptr ? gdk_display_get_name(display) : "unknown");
    logged_events++;
    if (logged_events == 32) {
      g_printerr("Sena Linux touch event logging suppressed after 32 events\n");
    }
  }
  return FALSE;
}

static void sena_enable_touch_events(GtkWidget* widget) {
  if (widget == nullptr || !GTK_IS_WIDGET(widget)) {
    return;
  }

  gtk_widget_set_can_focus(widget, TRUE);
  gtk_widget_add_events(widget,
                        GDK_TOUCH_MASK | GDK_BUTTON_PRESS_MASK |
                            GDK_BUTTON_RELEASE_MASK |
                            GDK_POINTER_MOTION_MASK |
                            GDK_SMOOTH_SCROLL_MASK);
  g_signal_connect(widget, "event", G_CALLBACK(sena_touch_event_probe),
                   nullptr);

  if (GTK_IS_CONTAINER(widget)) {
    GList* children = gtk_container_get_children(GTK_CONTAINER(widget));
    for (GList* child = children; child != nullptr; child = child->next) {
      sena_enable_touch_events(GTK_WIDGET(child->data));
    }
    g_list_free(children);
  }
}

"""
app_text = patch_once(
    app_text,
    helper_marker,
    "// Implements GApplication::activate.",
    helper_code,
)

call_marker = "sena_enable_touch_events(GTK_WIDGET(window));"
if call_marker not in app_text:
    anchor = "  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));\n"
    if anchor not in app_text:
        raise RuntimeError(f"Anchor not found: {anchor.strip()}")
    app_text = app_text.replace(
        anchor,
        anchor
        + "  sena_enable_touch_events(GTK_WIDGET(window));\n"
        + "  GdkDisplay* sena_display = gdk_display_get_default();\n"
        + "  g_printerr(\"Sena Linux GTK display: %s\\n\",\n"
        + "             sena_display != nullptr ? gdk_display_get_name(sena_display) : \"unknown\");\n",
        1,
    )

app_source.write_text(app_text, encoding="utf-8")
