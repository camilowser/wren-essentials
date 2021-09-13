// Extracted from https://github.com/domeengine/dome/blob/develop/src/modules/json.wren
// Loosely based on https://github.com/brandly/wren-json/blob/master/json.wren

class JSONOptions {
  #description = "No options"
  static nil { 0 }

  #description = "Escape `/` char"
  static escapeSolidus { 1 }

  #description = "Abort on Error"
  static abortOnError { 2 }

  #description = "Bool Nums and Null always as String"
  static primitivesAsString { 3 }

  #description = "Avoid infinite recursion"
  static checkCircular { 4 }

  #description = "true if `option` is within `options`"
  static contains(options, option) {
    return ((options & option) != JSONOptions.nil)
  }
}

class JSONError {
  line { _line }
  position { _position }
  message { _message }
  found { _found }

  construct new(line, pos, message, found) {
    _line = line
    _position = pos
    _message = message
    _found = found
  }

  construct abort(message) {
    var error = JSONError.new(0, 0, message, false)
    Fiber.abort(error)
  }

  static empty() {
    return JSONError.new(0, 0, "", false)
  }

  toString {"[Error] JSON | line: %(line) | pos: %(position) | %(message)"}
}

// pdjson.h:

// enum json_type {
//     JSON_ERROR = 1, JSON_DONE,
//     JSON_OBJECT, JSON_OBJECT_END, JSON_ARRAY, JSON_ARRAY_END,
//     JSON_STRING, JSON_NUMBER, JSON_TRUE, JSON_FALSE, JSON_NULL
// };

class Token {
  static isError { 1 }
  static isDone { 2 }
  static isObject { 3 }
  static isObjectEnd { 4 }
  static isArray { 5 }
  static isArrayEnd { 6 }
  static isString { 7 }
  static isNumeric { 8 }
  static isBoolTrue { 9 }
  static isBoolFalse { 10 }
  static isNull { 11 }
}

class JSONStream {
  foreign stream_begin(value)
  foreign stream_end()
  foreign next
  foreign value
  foreign error_message
  foreign lineno
  foreign pos

  result { _result }
  error { _error }
  options { _options }
  raw { _raw }

  construct new(raw, options) {
    _result = {}
    _error = JSONError.empty()
    _lastEvent = null
    _raw = raw
    _options = options
  }

  begin() {
    stream_begin(_raw)
    _result = process(next)
  }

  end() {
    stream_end()
  }

  process(event) {
    _lastEvent = event

    if (event == Token.isError) {
      _error = JSONError.new(lineno, pos, error_message, true)
      if (JSONOptions.contains(_options, JSONOptions.abortOnError)) {
        end()
        Fiber.abort(_error)
      }
      return
    }

    if (event == Token.isDone) {
      return
    }

    if (event == Token.isBoolTrue || event == Token.isBoolFalse) {
      return (event == Token.isBoolTrue)
    }

    if (event == Token.isNumeric) {
      return Num.fromString(this.value)
    }

    if (event == Token.isString) {
      return this.value
    }

    if (event == Token.isNull) {
      return null
    }

    if (event == Token.isArray) {
      var elements = []
      while (true) {
        event = next
        _lastEvent = event
        if (event == Token.isArrayEnd) {
          break
        }
        elements.add(process(event))
      }
      return elements
    }

    if (event == Token.isObject) {
      var elements = {}
      while (true) {
        event = next
        _lastEvent = event
        if (event == Token.isObjectEnd) {
            break
        }
        elements[this.value] = process(next)
      }
      return elements
    }
  }
}

// Protocol for JSON encodable values
// prefer implementing toJSON method instead of relying on toString
class JSONEncodable {
  toJSON {this.toString}
}

class JSONEscapeChars {
  static hexchars {["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "A", "B", "C", "D", "E", "F"]}

  static toHex(byte) {
    var hex = ""
    while (byte > 0) {
      var c = byte % 16
      hex = hexchars[c] + hex
      byte = byte >> 4
    }
    return hex
  }
  
  static lpad(s, count, with) {
    while (s.count < count) {
      s = "%(with)%(s)"
    }
    return s
  }

  static escape(text) {
    var substrings = []
    // Escape special characters
    for (char in text) {
      if (char == "\"") {
        substrings.add("\\\"")
      } else if (char == "\\") {
        substrings.add("\\\\")
      } else if (char == "\b") {
        substrings.add("\\b")
      } else if (char == "\f") {
        substrings.add("\\f")
      } else if (char == "\n") {
        substrings.add("\\n")
      } else if (char == "\r") {
        substrings.add("\\r")
      } else if (char == "\t") {
        substrings.add("\\t")
      } else if (char.bytes[0] <= 0x1f) {
        // Control characters!
        var byte = char.bytes[0]
        var hex = lpad(toHex(byte), 4, "0")
        substrings.add("\\u" + hex)
      } else {
        substrings.add(char)
      }
    }
    return "\"" + substrings.join("") + "\""
  }

  static escape(text, options) {
    var string = text

    // Escape / (solidus, slash)
    // https://stackoverflow.com/a/9735430
    // The feature of the slash escape allows JSON to be embedded in HTML (as SGML) and XML.
    // https://www.w3.org/TR/html4/appendix/notes.html#h-B.3.2
    // This is optional escaping. Disabled by default.
    // use JSONOptions.escapeSolidus option to enable it
    if (JSONOptions.contains(options, JSONOptions.escapeSolidus)) {
      var substrings = []
      for (char in string) {
        if (char == "/") {
          substrings.add("\\/")
        } else {
          substrings.add(char)
        }
      }
      string = substrings.join("")
    }

    return escape(string)
  }
}

class JSONEncoder {
  construct new(options) {
    _options = options
    _circularStack = JSONOptions.contains(options, JSONOptions.checkCircular) ? [] : null
  }

  isCircle(value) {
    if (_circularStack == null) {
      return false
    }
    return _circularStack.any { |v| Object.same(value, v) }
  }

  push(value) {
    if (_circularStack != null) {
      _circularStack.add(value)
    }
  }
  pop() {
    if (_circularStack != null) {
      _circularStack.removeAt(-1)
    }
  }

  encode(value) {
    if (isCircle(value)) {
      JSONError.abort("Circular JSON")
    }

    if (value is Num || value is Bool || value is Null) {
      
      if (JSONOptions.contains(_options, JSONOptions.primitivesAsString)) {
        return value.toString
      }

      return value
    }

    if (value is String) {
      // Escape special characters
      return JSONEscapeChars.escape(value, _options)
    }

    if (value is List) {
      push(value)
      var substrings = []
      for (item in value) {
        substrings.add(encode(item))
      }
      pop()
      return "[" + substrings.join(",") + "]"
    }

    if (value is Map) {
      push(value)
      var substrings = []
      for (key in value.keys) {
        var keyValue = this.encode(value[key])
        var encodedKey = this.encode(key)
        substrings.add("%(encodedKey):%(keyValue)")
      }
      pop()
      return "{" + substrings.join(",") + "}"
    }

    // Value is not a primitive
    // Check the protocol first
    if (value is JSONEncodable) {
      return value.toJSON
    }

    // Default behaviour is to invoke the toString method
    return value.toString
  }
}

class JSON {

  static defaultOptions {JSONOptions.abortOnError | JSONOptions.checkCircular}

  static encode(value, options) { JSONEncoder.new(options).encode(value) }

  static encode(value) {
    return JSON.encode(value, defaultOptions)
  }

  static decode(value, options) {
    var stream = JSONStream.new(value, options)
    stream.begin()

    var result = stream.result
    if (stream.error.found) {
      result = stream.error
    }

    stream.end()
    return result
  }

  static decode(value) {
    return JSON.decode(value, defaultOptions)
  }

  #alias(encode)

  static stringify(value, options) {
    return JSON.encode(value, options)
  }

  static stringify(value) {
    return JSON.encode(value)
  }

  #alias(decode)

  static parse(value, options) {
    return JSON.decode(value, options)
  }

  static parse(value) {
    return JSON.decode(value)
  }
}