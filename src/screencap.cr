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

            xdisplay.flush
          end
        else
          break
        end
      end
    end
    dimensions
  end

  def self.setup
    @@display = X.open_display nil

    if @@display.is_a? Nil
      puts "Failed to open display"
      exit 1
    end

    @@xdisplay = X11::Display.new @@display
    screen = X11::C.default_screen @@display
    @@width = X.display_width @@display, screen
    @@height = X.display_height @@display, screen
    @@pixel_black = X11::C.black_pixel @@display, screen
    @@pixel_white = X11::C.white_pixel @@display, screen
    @@root = X11::C.root_window @@display, screen
  end

  def self.configure
    @@window = X.create_simple_window @@display, @@root,
      0, 0, @@width, @@height, 0, @@pixel_black, @@pixel_white

    xattrs = X::SetWindowAttributes.new
    xattrs.override_redirect = 1
    attrs = X11::SetWindowAttributes.new xattrs

    X.change_window_attributes @@display, @@window,
      (CWBackPixmap | CWOverrideRedirect).to_u64, attrs

    changes = X11::WindowChanges.new
    changes.stack_mode = X11::C::Above
    X.configure_window @@display, @@window,
      (CWStackMode).to_u64, changes

    X.set_transient_for_hint @@display, @@window, @@root
    X.map_window @@display, @@window
  end

  def self.makegc
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

    @@xdisplay.create_gc @@root.as(X11::C::Drawable),
      valuemap,
      xgcvalues
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
        configure

        pointer = X.create_font_cursor @@display, X11::C::XC_CROSSHAIR
        X.grab_pointer @@display, @@root, 0,
          X11::C::ButtonMotionMask | X11::C::ButtonPressMask |
          X11::C::ButtonReleaseMask,
          X11::C::GrabModeAsync, X11::C::GrabModeAsync, @@root, pointer, 0
        selection = get_selection @@display, @@window, makegc
      }

      # fullscreen screenshot
      parser.on("-f", "--full", "Create a screenshot of the entire screen") {
        setup
        configure
        selection = [0, 0, @@width, @@height]
      }

      # window screenshot
      parser.on("-w", "--window", "Create a screenshot of the active window") {
        setup

        active = uninitialized X11::Window
        revert = uninitialized Int32
        X.get_input_focus @@display, pointerof(active), pointerof(revert)

        root = uninitialized X11::Window
        parent = uninitialized X11::Window
        children = uninitialized X11::Window*
        nchildren = uninitialized UInt32
        attrs = X::WindowAttributes.new

        width, height, x, y = 0, 0, 0, 0

        # walk window tree from our focus target to the root window
        #  because get_input_focus returns the wrong target
        #  on reparenting window managers
        while active != @@root
          X.query_tree @@display,
            active,
            pointerof(root),
            pointerof(parent),
            pointerof(children),
            pointerof(nchildren)
          active = parent
          X.get_window_attributes @@display, active, pointerof(attrs)
          unless attrs.x < 0 || attrs.y < 0
            if width == 0
              width += attrs.width
              height += attrs.height
            end
            x += attrs.x
            y += attrs.y
          end
        end

        selection = [x, y, width.to_u32, height.to_u32]
        configure
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

    exit 1 if selection.size < 4 # didn't select an area

    x, y, width, height = selection

    image = capture @@display, @@window, x, y, width, height

    # clean up
    X.destroy_window @@display, @@window
    X.close_display @@display

    # save image
    canvas = Canvas.new width.to_i32, height.to_i32

    # TODO: speed up (copy X image buffer directly instead of using get_pixel?)
    width.times do |x|
      height.times do |y|
        pixel = X.get_pixel image, x, y
        canvas[x, y] = RGBA.new *{16, 8, 0}.map { |n| ((pixel >> n & UInt8::MAX).to_f / UInt8::MAX * UInt16::MAX).to_u16 }, UInt16::MAX
      end
    end

    StumpyPNG.write canvas, "test.png"
  end

  main
end
