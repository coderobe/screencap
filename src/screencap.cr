require "./screencap/*"

require "option_parser"
require "x11"
require "stumpy_png"

module Screencap
  include X11
  include StumpyPNG

  @@display = uninitialized X::PDisplay
  @@xdisplay = uninitialized X11::Display
  @@pixel_black = uninitialized UInt64
  @@pixel_white = uninitialized UInt64
  @@root = uninitialized X11::Window
  @@window = uninitialized X11::Window
  @@width = uninitialized Int32
  @@height = uninitialized Int32

  def self.draw_selection(xdisplay, window, gc, dimensions)
    return if dimensions.size < 4
    xdisplay.draw_rectangle window.as(X11::C::Drawable), gc,
      dimensions[0].as(Int32), dimensions[1].as(Int32),
      dimensions[2].as(UInt32), dimensions[3].as(UInt32)
  end

  def self.repaint(xdisplay)
    xdisplay.flush
  end

  def self.get_selection(display, window, gc)
    xdisplay = X11::Display.new display
    clicked = false
    rect_x_start = 0
    rect_y_start = 0
    rect_x_end = 0
    rect_y_end = 0

    dimensions_prev = [] of (Int32 | UInt32)
    dimensions = [] of (Int32 | UInt32)

    event = uninitialized X::Event
    loop do
      if X.pending display
        X.next_event display, pointerof(event)
        case event.type
        when ButtonPress
          clicked = true
          rect_x_start = event.button.x_root
          rect_y_start = event.button.y_root
        when ButtonRelease
          clicked = false
          draw_selection xdisplay, window, gc, dimensions # remove selection rect
          return dimensions
          break # leave
        when MotionNotify
          if clicked
            rect_x_end = event.button.x_root
            rect_y_end = event.button.y_root

            dimensions = [
              Math.min(rect_x_start, rect_x_end),     # x
              Math.min(rect_y_start, rect_y_end),     # y
              (rect_x_start - rect_x_end).abs.to_u32, # width
              (rect_y_start - rect_y_end).abs.to_u32, # height
            ]

            # remove previous selection
            draw_selection xdisplay, window, gc, dimensions_prev unless dimensions_prev.size < 4
            dimensions_prev = dimensions

            # draw new selection
            draw_selection xdisplay, window, gc, dimensions

            repaint xdisplay
          end
        when Event
          break
        end
      end
    end
    dimensions
  end

  def self.setup
    display = X.open_display nil
    @@display = display

    if display.is_a? Nil
      puts "Failed to open display"
      exit 1
    end
    xdisplay = X11::Display.new display
    @@xdisplay = xdisplay

    screen = X11::C.default_screen display
    width = X.display_width display, screen
    @@width = width
    height = X.display_height display, screen
    @@height = height
    pixel_black = X11::C.black_pixel display, screen
    @@pixel_black = pixel_black
    pixel_white = X11::C.white_pixel display, screen
    @@pixel_white = pixel_white

    root = X11::C.root_window display, screen
    @@root = root

    window = X.create_simple_window display, root,
      0, 0, width, height, 0, pixel_black, pixel_white
    @@window = window

    xattrs = X::SetWindowAttributes.new
    # CDR: turns out not setting this but keeping CWBackPixmap
    #      enabled causes the background to inherit whatever is below
    #      which is just what we need.
    # xattrs.background_pixmap = img
    xattrs.override_redirect = 1
    attrs = X11::SetWindowAttributes.new xattrs

    X.change_window_attributes display, window,
      (CWBackPixmap | CWOverrideRedirect).to_u64, attrs

    changes = X11::WindowChanges.new
    changes.stack_mode = X11::C::Above
    X.configure_window display, window,
      (CWStackMode).to_u64, changes

    X.set_transient_for_hint display, window, root
    X.map_window display, window
  end

  def self.capture(display, window, x, y, width, height)
    X.get_image display, window,
      x, y, width, height, X.all_planes, X11::C::XYPixmap
  end

  def self.main
    selection = [] of (Int32 | UInt32) # => [x, y, width, height]

    OptionParser.parse! do |parser|
      parser.banner = "Usage: screencap [arguments]"

      # area screenshot
      parser.on("-a", "--area", "Create an area screenshot") {
        setup

        gcvalues = X::GCValues.new
        gcvalues.foreground = @@pixel_white
        gcvalues.background = @@pixel_black
        gcvalues.function = X11::C::GXinvert
        gcvalues.plane_mask = @@pixel_black ^ @@pixel_white
        gcvalues.subwindow_mode = X11::C::IncludeInferiors
        gcvalues.line_width = 1
        gcvalues.line_style = X11::C::LineOnOffDash
        xgcvalues = GCValues.new pointerof(gcvalues)

        valuemap_raw = X11::C::GCFunction | X11::C::GCForeground |
                       X11::C::GCBackground | X11::C::GCSubwindowMode |
                       X11::C::GCLineWidth | X11::C::GCLineStyle
        valuemap = valuemap_raw.to_u64

        gc = @@xdisplay.create_gc @@root.as(X11::C::Drawable),
          valuemap,
          xgcvalues

        pointer = X.create_font_cursor @@display, X11::C::XC_CROSSHAIR
        X.grab_pointer @@display, @@root, 0,
          X11::C::ButtonMotionMask | X11::C::ButtonPressMask |
          X11::C::ButtonReleaseMask,
          X11::C::GrabModeAsync, X11::C::GrabModeAsync, @@root, pointer, 0
        selection = get_selection @@display, @@window, gc
      }

      # fullscreen screenshot
      parser.on("-f", "--full", "Create a screenshot of the entire screen") {
        setup

        selection = [0, 0, @@width, @@height]
      }

      # help
      parser.on("-h", "--help", "Show this help") {
        puts parser
        exit 0
      }

      if ARGV.size < 1
        puts parser
        exit 0
      end
    end

    return if selection.size < 4 # didn't select an area

    image = capture @@display, @@window,
      selection[0], selection[1], selection[2], selection[3]

    # clean up
    X.destroy_window @@display, @@window
    X.close_display @@display

    # save image
    canvas = Canvas.new selection[2].to_i32, selection[3].to_i32
    selection[2].times do |x|
      selection[3].times do |y|
        pixel = X.get_pixel image, x, y
        bytes = Utils.uint32_to_bytes pixel
        canvas[x, y] = RGBA.from_rgb bytes[1], bytes[2], bytes[3]
      end
    end

    StumpyPNG.write canvas, "test.png"
  end

  main
end
