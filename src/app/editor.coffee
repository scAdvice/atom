{View, $$} = require 'space-pen'
Buffer = require 'buffer'
CompositeCursor = require 'composite-cursor'
CompositeSelection = require 'composite-selection'
Gutter = require 'gutter'
Renderer = require 'renderer'
Point = require 'point'
Range = require 'range'

$ = require 'jquery'
_ = require 'underscore'

module.exports =
class Editor extends View
  @idCounter: 1

  @content: ->
    @div class: 'editor', tabindex: -1, =>
      @input class: 'hidden-input', outlet: 'hiddenInput'
      @div class: 'flexbox', =>
        @subview 'gutter', new Gutter
        @div class: 'scroller', outlet: 'scroller', =>
          @div class: 'lines', outlet: 'lines', =>

  vScrollMargin: 2
  hScrollMargin: 10
  softWrap: false
  lineHeight: null
  charWidth: null
  charHeight: null
  cursor: null
  selection: null
  buffer: null
  highlighter: null
  renderer: null
  autoIndent: null
  lineCache: null
  isFocused: false
  softTabs: true
  tabText: '  '

  initialize: (editorState) ->
    requireStylesheet 'editor.css'
    requireStylesheet 'theme/twilight.css'

    @id = Editor.idCounter++
    @bindKeys()
    @autoIndent = true
    @buildCursorAndSelection()
    @handleEvents()
    @editorStatesByBufferId = {}
    @setEditorState(editorState)

  bindKeys: ->
    @on 'save', => @save()
    @on 'move-right', => @moveCursorRight()
    @on 'move-left', => @moveCursorLeft()
    @on 'move-down', => @moveCursorDown()
    @on 'move-up', => @moveCursorUp()
    @on 'move-to-next-word', => @moveCursorToNextWord()
    @on 'move-to-previous-word', => @moveCursorToPreviousWord()
    @on 'select-right', => @selectRight()
    @on 'select-left', => @selectLeft()
    @on 'select-up', => @selectUp()
    @on 'select-down', => @selectDown()
    @on 'newline', => @insertText("\n")
    @on 'tab', => @insertTab()
    @on 'indent-selected-rows', => @indentSelectedRows()
    @on 'outdent-selected-rows', => @outdentSelectedRows()
    @on 'backspace', => @backspace()
    @on 'backspace-to-beginning-of-word', => @backspaceToBeginningOfWord()
    @on 'delete', => @delete()
    @on 'delete-to-end-of-word', => @deleteToEndOfWord()
    @on 'cut-to-end-of-line', => @cutToEndOfLine()
    @on 'cut', => @cutSelection()
    @on 'copy', => @copySelection()
    @on 'paste', => @paste()
    @on 'undo', => @undo()
    @on 'redo', => @redo()
    @on 'toggle-soft-wrap', => @toggleSoftWrap()
    @on 'fold-selection', => @foldSelection()
    @on 'split-left', => @splitLeft()
    @on 'split-right', => @splitRight()
    @on 'split-up', => @splitUp()
    @on 'split-down', => @splitDown()
    @on 'close', => @remove(); false

    @on 'move-to-top', => @moveCursorToTop()
    @on 'move-to-bottom', => @moveCursorToBottom()
    @on 'move-to-beginning-of-line', => @moveCursorToBeginningOfLine()
    @on 'move-to-end-of-line', => @moveCursorToEndOfLine()
    @on 'move-to-first-character-of-line', => @moveCursorToFirstCharacterOfLine()
    @on 'move-to-beginning-of-word', => @moveCursorToBeginningOfWord()
    @on 'move-to-end-of-word', => @moveCursorToEndOfWord()
    @on 'select-to-top', => @selectToTop()
    @on 'select-to-bottom', => @selectToBottom()
    @on 'select-to-end-of-line', => @selectToEndOfLine()
    @on 'select-to-beginning-of-line', => @selectToBeginningOfLine()
    @on 'select-to-end-of-word', => @selectToEndOfWord()
    @on 'select-to-beginning-of-word', => @selectToBeginningOfWord()

  buildCursorAndSelection: ->
    @compositeSelection = new CompositeSelection(this)
    @compositeCursor = new CompositeCursor(this)

  addCursorAtScreenPosition: (screenPosition) ->
    @compositeCursor.addCursorAtScreenPosition(screenPosition)

  addCursorAtBufferPosition: (bufferPosition) ->
    @compositeCursor.addCursorAtBufferPosition(bufferPosition)

  addSelectionForCursor: (cursor) ->
    @compositeSelection.addSelectionForCursor(cursor)

  handleEvents: ->
    @on 'focus', =>
      @hiddenInput.focus()
      false

    @hiddenInput.on 'focus', =>
      @rootView()?.editorFocused(this)
      @isFocused = true
      @addClass 'focused'

    @hiddenInput.on 'focusout', =>
      @isFocused = false
      @removeClass 'focused'

    @lines.on 'mousedown', '.fold-placeholder', (e) =>
      @destroyFold($(e.currentTarget).attr('foldId'))
      false

    @lines.on 'mousedown', (e) =>
      clickCount = e.originalEvent.detail

      if clickCount == 1
        screenPosition = @screenPositionFromMouseEvent(e)
        if e.metaKey
          @addCursorAtScreenPosition(screenPosition)
        else if e.shiftKey
          @selectToScreenPosition(@screenPositionFromMouseEvent(e))
        else
          @setCursorScreenPosition(screenPosition)
      else if clickCount == 2
        if e.shiftKey
          @compositeSelection.getLastSelection().expandOverWord()
        else
          @compositeSelection.getLastSelection().selectWord()
      else if clickCount >= 3
        if e.shiftKey
          @compositeSelection.getLastSelection().expandOverLine()
        else
          @compositeSelection.getLastSelection().selectLine()

      @selectOnMousemoveUntilMouseup()

      return false

    @hiddenInput.on "textInput", (e) =>
      @insertText(e.originalEvent.data)

    @scroller.on 'scroll', =>
      @gutter.scrollTop(@scroller.scrollTop())
      if @scroller.scrollLeft() == 0
        @gutter.removeClass('drop-shadow')
      else
        @gutter.addClass('drop-shadow')

    @one 'attach', =>
      @calculateDimensions()
      @hiddenInput.width(@charWidth)
      @setMaxLineLength() if @softWrap
      @focus()

  rootView: ->
    @parents('#root-view').view()

  selectOnMousemoveUntilMouseup: ->
    moveHandler = (e) => @selectToScreenPosition(@screenPositionFromMouseEvent(e))
    @on 'mousemove', moveHandler
    $(document).one 'mouseup', =>
      @off 'mousemove', moveHandler
      reverse = @compositeSelection.getLastSelection().isReversed()
      @compositeSelection.mergeIntersectingSelections({reverse})
      @syncCursorAnimations()

  renderLines: ->
    @lineCache = []
    @lines.find('.line').remove()
    @insertLineElements(0, @buildLineElements(0, @getLastScreenRow()))

  getScreenLines: ->
    @renderer.getLines()

  linesForRows: (start, end) ->
    @renderer.linesForRows(start, end)

  screenLineCount: ->
    @renderer.lineCount()

  getLastScreenRow: ->
    @screenLineCount() - 1

  setBuffer: (buffer) ->
    if @buffer
      @saveEditorStateForCurrentBuffer()
      @unsubscribeFromBuffer()

    @buffer = buffer
    @trigger 'buffer-path-change'
    @buffer.on "path-change.editor#{@id}", => @trigger 'buffer-path-change'

    @renderer = new Renderer(@buffer, { maxLineLength: @calcMaxLineLength(), tabText: @tabText })
    @renderLines()
    @gutter.renderLineNumbers()

    @loadEditorStateForBuffer(@buffer)

    @buffer.on "change.editor#{@id}", (e) => @handleBufferChange(e)
    @renderer.on 'change', (e) => @handleRendererChange(e)

  loadEditorStateForBuffer: (buffer) ->
    editorState = (@editorStatesByBufferId[buffer.id] ?= {})
    @setCursorScreenPosition(editorState.cursorScreenPosition ? [0, 0])
    @scroller.scrollTop(editorState.scrollTop ? 0)
    @scroller.scrollLeft(editorState.scrollLeft ? 0)

  setEditorState: (editorState) ->
    buffer = editorState.buffer ? new Buffer
    @editorStatesByBufferId[buffer.id] = editorState
    @setBuffer(buffer)

  getEditorState: ->
    buffer: @buffer
    cursorScreenPosition: @getCursorScreenPosition().copy()
    scrollTop: @scroller.scrollTop()
    scrollLeft: @scroller.scrollLeft()

  saveEditorStateForCurrentBuffer: ->
    @editorStatesByBufferId[@buffer.id] = @getEditorState()

  handleBufferChange: (e) ->
    @compositeCursor.handleBufferChange(e)
    @compositeSelection.handleBufferChange(e)

  handleRendererChange: (e) ->
    { oldRange, newRange } = e
    unless newRange.isSingleLine() and newRange.coversSameRows(oldRange)
      @gutter.renderLineNumbers(@getScreenLines())

    @compositeCursor.updateBufferPosition() unless e.bufferChanged

    lineElements = @buildLineElements(newRange.start.row, newRange.end.row)
    @replaceLineElements(oldRange.start.row, oldRange.end.row, lineElements)

  buildLineElements: (startRow, endRow) ->
    charWidth = @charWidth
    charHeight = @charHeight
    lines = @renderer.linesForRows(startRow, endRow)
    $$ ->
      for line in lines
        @div class: 'line', =>
          appendNbsp = true
          for token in line.tokens
            if token.type is 'fold-placeholder'
              @span '   ', class: 'fold-placeholder', style: "width: #{3 * charWidth}px; height: #{charHeight}px;", 'foldId': token.fold.id, =>
                @div class: "ellipsis", => @raw "&hellip;"
            else
              appendNbsp = false
              @span { class: token.type.replace('.', ' ') }, token.value
          @raw '&nbsp;' if appendNbsp

  insertLineElements: (row, lineElements) ->
    @spliceLineElements(row, 0, lineElements)

  replaceLineElements: (startRow, endRow, lineElements) ->
    @spliceLineElements(startRow, endRow - startRow + 1, lineElements)

  spliceLineElements: (startRow, rowCount, lineElements) ->
    endRow = startRow + rowCount
    elementToInsertBefore = @lineCache[startRow]
    elementsToReplace = @lineCache[startRow...endRow]
    @lineCache[startRow...endRow] = lineElements?.toArray() or []

    lines = @lines[0]
    if lineElements
      fragment = document.createDocumentFragment()
      lineElements.each -> fragment.appendChild(this)
      if elementToInsertBefore
        lines.insertBefore(fragment, elementToInsertBefore)
      else
        lines.appendChild(fragment)

    elementsToReplace.forEach (element) =>
      lines.removeChild(element)

  getLineElement: (row) ->
    @lineCache[row]

  toggleSoftWrap: ->
    @setSoftWrap(not @softWrap)

  calcMaxLineLength: ->
    if @softWrap
      Math.floor(@scroller.width() / @charWidth)
    else
      Infinity

  setMaxLineLength: (maxLineLength) ->
    maxLineLength ?= @calcMaxLineLength()
    @renderer.setMaxLineLength(maxLineLength) if maxLineLength

  createFold: (range) ->
    @renderer.createFold(range)

  setSoftWrap: (@softWrap, maxLineLength=undefined) ->
    @setMaxLineLength(maxLineLength)
    if @softWrap
      @addClass 'soft-wrap'
      @_setMaxLineLength = => @setMaxLineLength()
      $(window).on 'resize', @_setMaxLineLength
    else
      @removeClass 'soft-wrap'
      $(window).off 'resize', @_setMaxLineLength

  save: ->
    if not @buffer.getPath()
      path = $native.saveDialog()
      return if not path
      @buffer.saveAs(path)
    else
      @buffer.save()

  clipScreenPosition: (screenPosition, options={}) ->
    @renderer.clipScreenPosition(screenPosition, options)

  pixelPositionForScreenPosition: (position) ->
    position = Point.fromObject(position)
    { top: position.row * @lineHeight, left: position.column * @charWidth }

  screenPositionFromPixelPosition: ({top, left}) ->
    screenPosition = new Point(Math.floor(top / @lineHeight), Math.floor(left / @charWidth))

  screenPositionForBufferPosition: (position, options) ->
    @renderer.screenPositionForBufferPosition(position, options)

  bufferPositionForScreenPosition: (position, options) ->
    @renderer.bufferPositionForScreenPosition(position, options)

  screenRangeForBufferRange: (range) ->
    @renderer.screenRangeForBufferRange(range)

  bufferRangeForScreenRange: (range) ->
    @renderer.bufferRangeForScreenRange(range)

  bufferRowsForScreenRows: ->
    @renderer.bufferRowsForScreenRows()

  screenPositionFromMouseEvent: (e) ->
    { pageX, pageY } = e
    @screenPositionFromPixelPosition
      top: pageY - @scroller.offset().top + @scroller.scrollTop()
      left: pageX - @scroller.offset().left + @scroller.scrollLeft()

  calculateDimensions: ->
    fragment = $('<div class="line" style="position: absolute; visibility: hidden;"><span>x</span></div>')
    @lines.append(fragment)
    @charWidth = fragment.width()
    @charHeight = fragment.find('span').height()
    @lineHeight = fragment.outerHeight()
    fragment.remove()

  getCursors: -> @compositeCursor.getCursors()
  moveCursorUp: -> @compositeCursor.moveUp()
  moveCursorDown: -> @compositeCursor.moveDown()
  moveCursorRight: -> @compositeCursor.moveRight()
  moveCursorLeft: -> @compositeCursor.moveLeft()
  moveCursorToNextWord: -> @compositeCursor.moveToNextWord()
  moveCursorToBeginningOfWord: -> @compositeCursor.moveToBeginningOfWord()
  moveCursorToEndOfWord: -> @compositeCursor.moveToEndOfWord()
  moveCursorToTop: -> @compositeCursor.moveToTop()
  moveCursorToBottom: -> @compositeCursor.moveToBottom()
  moveCursorToBeginningOfLine: -> @compositeCursor.moveToBeginningOfLine()
  moveCursorToFirstCharacterOfLine: -> @compositeCursor.moveToFirstCharacterOfLine()
  moveCursorToEndOfLine: -> @compositeCursor.moveToEndOfLine()
  setCursorScreenPosition: (position) -> @compositeCursor.setScreenPosition(position)
  getCursorScreenPosition: -> @compositeCursor.getCursor().getScreenPosition()
  setCursorBufferPosition: (position) -> @compositeCursor.setBufferPosition(position)
  getCursorBufferPosition: -> @compositeCursor.getCursor().getBufferPosition()

  getSelection: (index) -> @compositeSelection.getSelection(index)
  getSelections: -> @compositeSelection.getSelections()
  getSelectionsOrderedByBufferPosition: -> @compositeSelection.getSelectionsOrderedByBufferPosition()
  getLastSelectionInBuffer: -> @compositeSelection.getLastSelectionInBuffer()
  getSelectedText: -> @compositeSelection.getSelection().getText()
  setSelectionBufferRange: (bufferRange, options) -> @compositeSelection.setBufferRange(bufferRange, options)
  setSelectedBufferRanges: (bufferRanges) -> @compositeSelection.setBufferRanges(bufferRanges)
  addSelectionForBufferRange: (bufferRange, options) -> @compositeSelection.addSelectionForBufferRange(bufferRange, options)
  selectRight: -> @compositeSelection.selectRight()
  selectLeft: -> @compositeSelection.selectLeft()
  selectUp: -> @compositeSelection.selectUp()
  selectDown: -> @compositeSelection.selectDown()
  selectToTop: -> @compositeSelection.selectToTop()
  selectToBottom: -> @compositeSelection.selectToBottom()
  selectToBeginningOfLine: -> @compositeSelection.selectToBeginningOfLine()
  selectToEndOfLine: -> @compositeSelection.selectToEndOfLine()
  selectToBeginningOfWord: -> @compositeSelection.selectToBeginningOfWord()
  selectToEndOfWord: -> @compositeSelection.selectToEndOfWord()
  selectToScreenPosition: (position) -> @compositeSelection.selectToScreenPosition(position)
  clearSelections: -> @compositeSelection.clearSelections()
  backspace: -> @compositeSelection.backspace()
  backspaceToBeginningOfWord: -> @compositeSelection.backspaceToBeginningOfWord()
  delete: -> @compositeSelection.delete()
  deleteToEndOfWord: -> @compositeSelection.deleteToEndOfWord()
  cutToEndOfLine: -> @compositeSelection.cutToEndOfLine()

  setText: (text) -> @buffer.setText(text)
  getText: -> @buffer.getText()
  getLastBufferRow: -> @buffer.getLastRow()
  getTextInRange: (range) -> @buffer.getTextInRange(range)
  getEofPosition: -> @buffer.getEofPosition()
  lineForBufferRow: (row) -> @buffer.lineForRow(row)
  lineLengthForBufferRow: (row) -> @buffer.lineLengthForRow(row)
  rangeForBufferRow: (row) -> @buffer.rangeForRow(row)
  scanInRange: (args...) -> @buffer.scanInRange(args...)
  backwardsScanInRange: (args...) -> @buffer.backwardsScanInRange(args...)

  insertText: (text) ->
    @compositeSelection.insertText(text)

  insertTab: ->
    if @softTabs
      @compositeSelection.insertText(@tabText)
    else
      @compositeSelection.insertText('\t')

  indentSelectedRows: -> @compositeSelection.indentSelectedRows()
  outdentSelectedRows: -> @compositeSelection.outdentSelectedRows()

  cutSelection: -> @compositeSelection.cut()
  copySelection: -> @compositeSelection.copy()
  paste: -> @insertText($native.readFromPasteboard())

  foldSelection: -> @getSelection().fold()

  undo: ->
    if ranges = @buffer.undo()
      @setSelectedBufferRanges(ranges)

  redo: ->
    if ranges = @buffer.redo()
      @setSelectedBufferRanges(ranges)

  destroyFold: (foldId) ->
    fold = @renderer.foldsById[foldId]
    fold.destroy()
    @setCursorBufferPosition(fold.start)

  splitLeft: ->
    @split('row', 'before')

  splitRight: ->
    @split('row', 'after')

  splitUp: ->
    @split('column', 'before')

  splitDown: ->
    @split('column', 'after')

  split: (axis, side) ->
    return unless rootView = @rootView()
    editor = new Editor(@getEditorState())
    rootView.addPane(editor, this, axis, side)

  remove: (selector, keepData) ->
    return super if keepData
    @unsubscribeFromBuffer()
    rootView = @rootView()
    parent = @parent()
    super
    parent.remove() if parent.is('.row:empty, .column:empty')
    rootView?.editorRemoved(this)

  unsubscribeFromBuffer: ->
    @buffer.off ".editor#{@id}"
    @renderer.destroy()

  stateForScreenRow: (row) ->
    @renderer.lineForRow(row).state

  getCurrentMode: ->
    @buffer.getMode()

  scrollTo: (pixelPosition) ->
    _.defer => # Optimization
      @scrollVertically(pixelPosition)
      @scrollHorizontally(pixelPosition)

  scrollVertically: (pixelPosition) ->
    linesInView = @scroller.height() / @lineHeight
    maxScrollMargin = Math.floor((linesInView - 1) / 2)
    scrollMargin = Math.min(@vScrollMargin, maxScrollMargin)
    margin = scrollMargin * @lineHeight
    desiredTop = pixelPosition.top - margin
    desiredBottom = pixelPosition.top + @lineHeight + margin

    if desiredBottom > @scroller.scrollBottom()
      @scroller.scrollBottom(desiredBottom)
    else if desiredTop < @scroller.scrollTop()
      @scroller.scrollTop(desiredTop)

  scrollHorizontally: (pixelPosition) ->
    return if @softWrap

    charsInView = @scroller.width() / @charWidth
    maxScrollMargin = Math.floor((charsInView - 1) / 2)
    scrollMargin = Math.min(@hScrollMargin, maxScrollMargin)
    margin = scrollMargin * @charWidth
    desiredRight = pixelPosition.left + @charWidth + margin
    desiredLeft = pixelPosition.left - margin

    if desiredRight > @scroller.scrollRight()
      @scroller.scrollRight(desiredRight)
    else if desiredLeft < @scroller.scrollLeft()
      @scroller.scrollLeft(desiredLeft)

  syncCursorAnimations: ->
    for cursor in @getCursors()
      do (cursor) -> cursor.resetCursorAnimation()

  logLines: ->
    @renderer.logLines()
