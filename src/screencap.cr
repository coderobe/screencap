require "./screencap/*"

require "x11"
require "stumpy_png"

module Screencap
  include X11
  include StumpyPNG

  @@display = uninitialized X11::Display
  @@root = uninitialized X11::Window
  @@gc = uninitialized Pointer(UInt8)
  @@dimensions = [] of (Int32 | UInt32)
  @@width = 0
  @@height = 0

  def self.renderer(dimensions)
    @@display.draw_rectangle @@root.as(X11::C::Drawable), @@gc,
      dimensions[0].as(Int32), dimensions[1].as(Int32),
      dimensions[2].as(UInt32), dimensions[3].as(UInt32)
    @@display.flush
  end

  def self.main
    display = uninitialized X::PDisplay
    display = X.open_display nil

    if display.is_a? Nil
      puts "Failed to open display"
      return 1
    end
    xdisplay = X11::Display.new display
    @@display = xdisplay

    screen = X11::C.default_screen display
    @@width = X.display_width display, screen
    @@height = X.display_height display, screen
    pixel_black = X11::C.black_pixel display, screen
    pixel_white = X11::C.white_pixel display, screen

    root = X11::C.root_window display, screen

    @@root = X.create_simple_window display, root,
      0, 0, @@width, @@height, 0, pixel_black, pixel_white

    xattrs = X::SetWindowAttributes.new
    # CDR: turns out not setting this but keeping CWBackPixmap
    #      enabled causes the background to inherit whatever is below
    #      which is just what we need.
    # xattrs.background_pixmap = img
    xattrs.override_redirect = 1
    attrs = X11::SetWindowAttributes.new xattrs

    X.change_window_attributes display, @@root,
      (CWBackPixmap | CWOverrideRedirect).to_u64, attrs

    changes = X11::WindowChanges.new
    changes.stack_mode = X11::C::Above
    X.configure_window display, @@root,
      (CWStackMode).to_u64, changes

    X.set_transient_for_hint display, @@root, root
    X.map_window display, @@root

    img = X.get_image display, @@root,
      0, 0, @@width, @@height, X.all_planes, X11::C::XYPixmap

    gcvalues = X::GCValues.new
    gcvalues.foreground = pixel_white
    gcvalues.background = pixel_black
    gcvalues.function = X11::C::GXinvert
    gcvalues.plane_mask = pixel_black ^ pixel_white
    gcvalues.subwindow_mode = X11::C::IncludeInferiors
    gcvalues.line_width = 1
    gcvalues.line_style = X11::C::LineOnOffDash
    gcvalues.fill_style = X11::C::FillOpaqueStippled
    xgcvalues = GCValues.new pointerof(gcvalues)

    valuemap_raw = X11::C::GCFunction | X11::C::GCForeground |
                   X11::C::GCBackground | X11::C::GCSubwindowMode |
                   X11::C::GCLineWidth | X11::C::GCLineStyle |
                   X11::C::GCFillStyle
    valuemap = valuemap_raw.to_u64

    gc = xdisplay.create_gc root.as(X11::C::Drawable),
      valuemap,
      xgcvalues
    @@gc = gc

    pointer = X.create_font_cursor display, X11::C::XC_CROSSHAIR
    X.grab_pointer display, root, 0,
      X11::C::ButtonMotionMask | X11::C::ButtonPressMask |
      X11::C::ButtonReleaseMask,
      X11::C::GrabModeAsync, X11::C::GrabModeAsync, root, pointer,
      0

    clicked = false
    rect_x_start = 0
    rect_y_start = 0
    rect_x_end = 0
    rect_y_end = 0
    dimensions = [] of (Int32 | UInt32)

    event = uninitialized X::Event
    loop do
      if X.pending display
        X.next_event display, pointerof(event)
        print "event pending: "
        case event.type
        when ButtonPress
          puts "down"
          clicked = true
          rect_x_start = event.button.x_root
          rect_y_start = event.button.y_root
        when ButtonRelease
          puts "up"
          clicked = false
          break # leave
        when MotionNotify
          puts "motion"
          if clicked
            p event.button.inspect

            rect_x_end = event.button.x_root
            rect_y_end = event.button.y_root

            dimensions = [
              Math.min(rect_x_start, rect_x_end),     # x
              Math.min(rect_y_start, rect_y_end),     # y
              (rect_x_start - rect_x_end).abs.to_u32, # width
              (rect_y_start - rect_y_end).abs.to_u32, # height
            ]

            renderer @@dimensions unless @@dimensions.size < 4
            @@dimensions = dimensions
            renderer @@dimensions
          end
        when Event
          break
        end
      end
    end

    canvas = Canvas.new @@dimensions[2].to_i32, @@dimensions[3].to_i32
    @@dimensions[2].times do |x|
      @@dimensions[3].times do |y|
        pixel = X.get_pixel img, @@dimensions[0] + x, @@dimensions[1] + y
        bpixel = Utils.uint32_to_bytes pixel

        canvas[x, y] = RGBA.from_rgb bpixel[1], bpixel[2], bpixel[3]
      end
    end

    StumpyPNG.write canvas, "test.png"

    X.destroy_window display, @@root
    X.close_display display
  end

  main
end
