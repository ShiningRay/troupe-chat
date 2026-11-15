# TroupeChat 自定义组件：布局壳（VBox/HBox 拉伸槽位）、聊天记录、成员列表。
#
# Kit 的 Column/Row 只做"子项各自 intrinsic 高/宽"的线性布局，没有 flex 槽位；
# 聊天窗口需要"中间区域吃掉剩余空间"，因此自写两支最小布局组件。
# ChatLog 参考 tessell examples/apps/text_editor_app.cr 的 EditorView 自绘模式。

require "tessell/kit"
require "protocol"

module ChatUI
  # 垂直布局：flex 权重为 nil 的子项按 intrinsic 高度，带权重的平分剩余高度。
  class VBox < Tessell::Kit::Component
    @children = [] of Tessell::Kit::Component
    @flexes = [] of Float32?

    def initialize(@key : Tessell::UI::UiKey, @gap : Float32 = 0.0_f32,
                   @padding : Tessell::Insets = Tessell::Insets.new)
      super(@key)
    end

    def add(child : Tessell::Kit::Component, flex : Float32? = nil) : Nil
      attach(child)
      @children << child
      @flexes << flex
    end

    # 摘除子组件（动态面板切换）：detach + 断父链，同 Kit Container#remove。
    def remove(child : Tessell::Kit::Component) : Bool
      idx = @children.index(child)
      return false unless idx
      @children.delete_at(idx)
      @flexes.delete_at(idx)
      child.parent = nil
      true
    end

    def measure(ctx : Tessell::Kit::Context, constraints : Tessell::Constraints) : Tessell::Size
      loose = Tessell::Constraints.new(0.0_f32, 100000.0_f32, 0.0_f32, 100000.0_f32)
      @sizes.clear
      total_h = 0.0_f32
      max_w = 0.0_f32
      @children.each do |child|
        s = child.measure(ctx, loose)
        @sizes << s
        total_h += s.height
        max_w = Math.max(max_w, s.width)
      end
      total_h += @gap * (@children.size - 1).clamp(0, Int32::MAX).to_f32
      # 内聚尺寸即可：填充由 arrange 的 flex/拉伸决定（与 Kit Container 同口径）。
      h = constraints.max_height.infinite? ? total_h : Math.min(constraints.max_height, total_h)
      w = constraints.max_width.infinite? ? max_w : Math.min(constraints.max_width, max_w)
      constraints.constrain(Tessell::Size.new(w, h))
    end

    def arrange(ctx : Tessell::Kit::Context, bounds : Tessell::Rect) : Nil
      @bounds = bounds
      inner = Tessell::Kit::Geometry.inset(bounds, @padding)
      inner_h = inner.size.height
      # 与 Kit Container 同口径：arrange 前重新 measure，保证 @sizes 有效且最新。
      child_constraints = Tessell::Constraints.new(0.0_f32, inner.size.width, 0.0_f32, inner_h)
      @sizes.clear
      @children.each { |child| @sizes << child.measure(ctx, child_constraints) }
      fixed = 0.0_f32
      flex_total = 0.0_f32
      @children.each_with_index do |_, i|
        if (f = @flexes[i])
          flex_total += f
        else
          fixed += @sizes[i].height
        end
      end
      fixed += @gap * (@children.size - 1).clamp(0, Int32::MAX).to_f32
      free = (inner_h - fixed).clamp(0.0_f32, inner_h)
      cursor = inner.origin.y
      @children.each_with_index do |child, i|
        h = if (f = @flexes[i]) && flex_total > 0
              free * (f / flex_total)
            else
              @sizes[i].height
            end
        child.arrange(ctx, Tessell::Rect.new(inner.origin.x, cursor, inner.size.width, h))
        cursor += h + @gap
      end
    end

    def emit(b : Tessell::UI::Builder, ctx : Tessell::Kit::Context) : Nil
      return unless @visible
      # 与 Kit Container 同口径：group 节点递归 emit 子树（命中树/绘制树入口）。
      b.group(@key, @bounds) do
        @children.each { |child| child.emit(b, ctx) }
      end
    end

    def paint(p : Tessell::Kit::Painter, ctx : Tessell::Kit::Context) : Nil
      return unless @visible
      @children.each { |child| child.paint(p, ctx) }
    end

    @sizes = [] of Tessell::Size
  end

  # 水平布局：flex 为 nil 的子项按 intrinsic 宽度，带权重的平分剩余宽度。
  class HBox < Tessell::Kit::Component
    @children = [] of Tessell::Kit::Component
    @flexes = [] of Float32?
    @sizes = [] of Tessell::Size

    def initialize(@key : Tessell::UI::UiKey, @gap : Float32 = 0.0_f32,
                   @padding : Tessell::Insets = Tessell::Insets.new)
      super(@key)
    end

    def add(child : Tessell::Kit::Component, flex : Float32? = nil) : Nil
      attach(child)
      @children << child
      @flexes << flex
    end

    def remove(child : Tessell::Kit::Component) : Bool
      idx = @children.index(child)
      return false unless idx
      @children.delete_at(idx)
      @flexes.delete_at(idx)
      child.parent = nil
      true
    end

    def measure(ctx : Tessell::Kit::Context, constraints : Tessell::Constraints) : Tessell::Size
      loose = Tessell::Constraints.new(0.0_f32, 100000.0_f32, 0.0_f32, 100000.0_f32)
      @sizes.clear
      total_w = 0.0_f32
      max_h = 0.0_f32
      @children.each do |child|
        s = child.measure(ctx, loose)
        @sizes << s
        total_w += s.width
        max_h = Math.max(max_h, s.height)
      end
      total_w += @gap * (@children.size - 1).clamp(0, Int32::MAX).to_f32
      w = constraints.max_width.infinite? ? total_w : Math.min(constraints.max_width, total_w)
      h = constraints.max_height.infinite? ? max_h : Math.min(constraints.max_height, max_h)
      constraints.constrain(Tessell::Size.new(w, h))
    end

    def arrange(ctx : Tessell::Kit::Context, bounds : Tessell::Rect) : Nil
      @bounds = bounds
      inner = Tessell::Kit::Geometry.inset(bounds, @padding)
      # 与 Kit Container 同口径：arrange 前重新 measure，保证 @sizes 有效且最新。
      child_constraints = Tessell::Constraints.new(0.0_f32, inner.size.width, 0.0_f32, inner.size.height)
      @sizes.clear
      @children.each { |child| @sizes << child.measure(ctx, child_constraints) }
      fixed = 0.0_f32
      flex_total = 0.0_f32
      @children.each_with_index do |_, i|
        if (f = @flexes[i])
          flex_total += f
        else
          fixed += @sizes[i].width
        end
      end
      fixed += @gap * (@children.size - 1).clamp(0, Int32::MAX).to_f32
      free = (inner.size.width - fixed).clamp(0.0_f32, inner.size.width)
      cursor = inner.origin.x
      @children.each_with_index do |child, i|
        w = if (f = @flexes[i]) && flex_total > 0
              free * (f / flex_total)
            else
              @sizes[i].width
            end
        child.arrange(ctx, Tessell::Rect.new(cursor, inner.origin.y, w, inner.size.height))
        cursor += w + @gap
      end
    end

    def emit(b : Tessell::UI::Builder, ctx : Tessell::Kit::Context) : Nil
      return unless @visible
      b.group(@key, @bounds) do
        @children.each { |child| child.emit(b, ctx) }
      end
    end

    def paint(p : Tessell::Kit::Painter, ctx : Tessell::Kit::Context) : Nil
      return unless @visible
      @children.each { |child| child.paint(p, ctx) }
    end
  end

  # 聊天记录：自绘换行列表，自动吸底，滚轮翻阅历史。
  class ChatLog < Tessell::Kit::Component
    record Row, head : String, body : String, mine : Bool, system : Bool
    record Line, text : String, color : UInt32, indent : Float32

    @rows = [] of Row
    @lines = [] of Line
    @content_h = 0.0_f32
    @scroll_y = 0.0_f32
    @follow = true
    @dirty = true
    @last_w = -1.0_f32
    @font_size : Float32 = 14.0_f32

    def initialize(@key : Tessell::UI::UiKey)
      super(@key, true, true)
    end

    def set_rows(rows : Array(Row)) : Nil
      @rows = rows
      @dirty = true
      jump_bottom if @follow
    end

    def jump_bottom : Nil
      @follow = true
    end

    def scroll_by(dy : Float32) : Nil
      @scroll_y = (@scroll_y - dy).clamp(0.0_f32, Float32::INFINITY)
      @follow = @scroll_y >= @content_h - view_height - 2.0_f32
    end

    def measure(ctx : Tessell::Kit::Context, constraints : Tessell::Constraints) : Tessell::Size
      w = constraints.max_width.infinite? ? 480.0_f32 : constraints.max_width
      h = constraints.max_height.infinite? ? 420.0_f32 : constraints.max_height
      constraints.constrain(Tessell::Size.new(w, h))
    end

    def arrange(ctx : Tessell::Kit::Context, bounds : Tessell::Rect) : Nil
      @bounds = bounds
    end

    def emit(b : Tessell::UI::Builder, ctx : Tessell::Kit::Context) : Nil
      return unless @visible
      b.node(@key, @bounds, a11y_role: Tessell::A11y::Role::List, a11y_name: "聊天记录")
    end

    def paint(p : Tessell::Kit::Painter, ctx : Tessell::Kit::Context) : Nil
      return unless @visible
      p.fill_round_rect(@bounds, ctx.theme.metrics.radius_md, ctx.theme.palette.surface)
      p.stroke_round_rect(@bounds, ctx.theme.metrics.radius_md, ctx.theme.palette.border,
        ctx.theme.metrics.border_width)
      inner = Tessell::Kit::Geometry.inset(@bounds, 10.0_f32)
      if inner.size.width <= 0 || inner.size.height <= 0
        return
      end
      p.push_clip(inner)
      rebuild_if_needed(ctx, inner.size.width)
      max_scroll = Math.max(0.0_f32, @content_h - inner.size.height)
      @scroll_y = @scroll_y.clamp(0.0_f32, max_scroll)
      line_h = line_height(ctx)
      visible_h = inner.size.height
      @lines.each_with_index do |line, _i|
        y = line_top(_i, line_h) - @scroll_y
        next if y + line_h <= inner.origin.y || y >= inner.origin.y + visible_h
        p.text(inner.origin.x + line.indent, y + line_h - 4.0_f32, line.text,
          line.color, @font_size)
      end
      p.pop_clip
      paint_scrollbar(p, ctx, inner, max_scroll)
    end

    def handle(event : Tessell::Kit::Event, ctx : Tessell::Kit::Context) : Bool
      case event.kind
      when Tessell::Kit::Event::Kind::Wheel
        scroll_by(event.wheel_dy)
        true
      else
        false
      end
    end

    private def line_top(index : Int32, line_h : Float32) : Float32
      # lines 顺序绘制，行高固定；头行与正文行同高。
      @line_tops[index]
    end

    @line_tops = [] of Float32

    private def rebuild_if_needed(ctx : Tessell::Kit::Context, width : Float32) : Nil
      return unless @dirty || width != @last_w
      @last_w = width
      @dirty = false
      @lines.clear
      @line_tops.clear
      @content_h = 0.0_f32
      palette = ctx.theme.palette
      @rows.each do |row|
        if row.system
          push_lines(ctx, row.body, palette.muted, 0.0_f32, width)
        else
          head_color = row.mine ? palette.accent : palette.success
          push_lines(ctx, row.head, head_color, 0.0_f32, width)
          body_color = row.mine ? palette.foreground : palette.foreground
          push_lines(ctx, row.body, body_color, 14.0_f32, width)
        end
        @content_h += 6.0_f32 # 消息间距
      end
      if @follow
        @scroll_y = Math.max(0.0_f32, @content_h)
      end
    end

    private def push_lines(ctx : Tessell::Kit::Context, text : String, color : UInt32,
                           indent : Float32, width : Float32) : Nil
      avail = width - indent
      wrapped = wrap_text(ctx, text, @font_size, avail)
      wrapped.each do |line|
        @line_tops << @content_h
        @lines << Line.new(line, color, indent)
        @content_h += line_height(ctx)
      end
    end

    private def line_height(ctx : Tessell::Kit::Context) : Float32
      ctx.line_height(@font_size) + 3.0_f32
    end

    private def view_height : Float32
      Tessell::Kit::Geometry.inset(@bounds, 10.0_f32).size.height
    end

    # 逐字符累计宽度换行（CJK/拉丁通吃；演示规模足够，带缓存）。
    private def wrap_text(ctx : Tessell::Kit::Context, text : String,
                          fs : Float32, max_w : Float32) : Array(String)
      return [""] if text.empty?
      lines = [""] of String
      line_w = 0.0_f32
      text.each_char do |ch|
        if ch == '\n'
          lines << ""
          line_w = 0.0_f32
          next
        end
        w = ctx.measure_text(ch.to_s, fs).width
        if line_w + w > max_w && lines.last != ""
          lines << ""
          line_w = 0.0_f32
          next if ch == ' '
        end
        lines[lines.size - 1] += ch
        line_w += w
      end
      lines
    end

    private def paint_scrollbar(p : Tessell::Kit::Painter, ctx : Tessell::Kit::Context,
                                inner : Tessell::Rect, max_scroll : Float32) : Nil
      return if max_scroll <= 0
      track_w = 6.0_f32
      track_x = @bounds.max_x - track_w - 3.0_f32
      p.fill_rect(Tessell::Rect.new(track_x, inner.origin.y, track_w, inner.size.height),
        ctx.theme.palette.surface_raised)
      ratio = (inner.size.height / (inner.size.height + max_scroll)).clamp(0.05_f32, 1.0_f32)
      thumb_h = inner.size.height * ratio
      travel = inner.size.height - thumb_h
      thumb_y = inner.origin.y + travel * (@scroll_y / max_scroll)
      p.fill_round_rect(Tessell::Rect.new(track_x + 1.0_f32, thumb_y, track_w - 2.0_f32, thumb_h),
        2.0_f32, ctx.theme.palette.muted)
    end

    def self.from_messages(messages : Array(Chat::Protocol::ChatMessage), you : String) : Array(Row)
      rows = [] of Row
      messages.each do |m|
        if m.from.empty?
          rows << Row.new("", m.text, false, true)
        else
          ts = Time.unix_ms(m.ts).to_s("%H:%M")
          mark = m.from == you ? "（我）" : ""
          rows << Row.new("[#{ts}] #{m.from}#{mark}", m.text, m.from == you, false)
        end
      end
      rows
    end
  end

  # 在线成员面板：固定宽度的自绘名单。
  class MembersPanel < Tessell::Kit::Component
    @members = [] of String
    @you : String = ""

    def initialize(@key : Tessell::UI::UiKey, @width : Float32 = 170.0_f32)
      super(@key, true, true)
    end

    property you

    def set_members(members : Array(String)) : Nil
      @members = members
    end

    def measure(ctx : Tessell::Kit::Context, constraints : Tessell::Constraints) : Tessell::Size
      h = constraints.max_height.infinite? ? 420.0_f32 : constraints.max_height
      constraints.constrain(Tessell::Size.new(@width, h))
    end

    def arrange(ctx : Tessell::Kit::Context, bounds : Tessell::Rect) : Nil
      @bounds = bounds
    end

    def emit(b : Tessell::UI::Builder, ctx : Tessell::Kit::Context) : Nil
      return unless @visible
      b.node(@key, @bounds, a11y_role: Tessell::A11y::Role::List, a11y_name: "在线成员")
    end

    def paint(p : Tessell::Kit::Painter, ctx : Tessell::Kit::Context) : Nil
      return unless @visible
      p.fill_round_rect(@bounds, ctx.theme.metrics.radius_md, ctx.theme.palette.surface)
      p.stroke_round_rect(@bounds, ctx.theme.metrics.radius_md, ctx.theme.palette.border,
        ctx.theme.metrics.border_width)
      fs = 14.0_f32
      lh = ctx.line_height(fs) + 4.0_f32
      inner = Tessell::Kit::Geometry.inset(@bounds, 10.0_f32)
      p.push_clip(inner)
      p.text(inner.origin.x, inner.origin.y + fs + 2.0_f32,
        "在线 #{@members.size}", ctx.theme.palette.muted, fs - 2.0_f32)
      y = inner.origin.y + lh + fs
      @members.each do |name|
        break if y > @bounds.max_y
        color = name == @you ? ctx.theme.palette.accent : ctx.theme.palette.foreground
        label = name == @you ? "#{name}（我）" : name
        p.text(inner.origin.x, y, label, color, fs)
        y += lh
      end
      p.pop_clip
    end
  end
end
