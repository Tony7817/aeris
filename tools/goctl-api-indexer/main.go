package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

type rangeItem struct {
	Kind      string  `json:"kind"`
	Name      string  `json:"name"`
	File      string  `json:"file"`
	Line      int     `json:"line"`
	Column    int     `json:"column"`
	EndColumn int     `json:"end_column"`
	Group     string  `json:"group,omitempty"`
	Target    *target `json:"target,omitempty"`
}

type target struct {
	File   string `json:"file"`
	Line   int    `json:"line"`
	Column int    `json:"column"`
}

type index struct {
	Files   []string    `json:"files"`
	Jumps   []rangeItem `json:"jumps"`
	Symbols []rangeItem `json:"symbols"`
}

type builder struct {
	visited map[string]bool
	files   []string
	defs    map[string]target
	jumps   []rangeItem
	symbols []rangeItem
}

var (
	importLinePattern = regexp.MustCompile(`^\s*import\s+"([^"]+)"`)
	typeLinePattern   = regexp.MustCompile(`^\s*type\s+([A-Za-z_][A-Za-z0-9_]*)\b`)
	typeNamePattern   = regexp.MustCompile(`^\s*([A-Za-z_][A-Za-z0-9_]*)\b`)
	handlerPattern    = regexp.MustCompile(`@handler\s+([A-Za-z_][A-Za-z0-9_]*)`)
	routeTypePattern  = regexp.MustCompile(`\(([A-Za-z_][A-Za-z0-9_]*)\)`)
	identifierPattern = regexp.MustCompile(`[A-Za-z_][A-Za-z0-9_]*`)
)

var builtInTypes = map[string]bool{
	"any":        true,
	"bool":       true,
	"byte":       true,
	"complex64":  true,
	"complex128": true,
	"error":      true,
	"float32":    true,
	"float64":    true,
	"int":        true,
	"int8":       true,
	"int16":      true,
	"int32":      true,
	"int64":      true,
	"interface":  true,
	"map":        true,
	"rune":       true,
	"string":     true,
	"uint":       true,
	"uint8":      true,
	"uint16":     true,
	"uint32":     true,
	"uint64":     true,
	"uintptr":    true,
}

func main() {
	if len(os.Args) != 2 {
		fmt.Fprintln(os.Stderr, "usage: goctl-api-indexer <file.api>")
		os.Exit(2)
	}

	path, err := filepath.Abs(os.Args[1])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}

	b := &builder{
		visited: make(map[string]bool),
		defs:    make(map[string]target),
	}
	if err := b.parseFile(path); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	b.resolveTypeTargets()

	output := index{
		Files:   b.files,
		Jumps:   b.jumps,
		Symbols: b.symbols,
	}
	encoder := json.NewEncoder(os.Stdout)
	if err := encoder.Encode(output); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func (b *builder) parseFile(path string) error {
	path = filepath.Clean(path)
	if b.visited[path] {
		return nil
	}
	b.visited[path] = true
	b.files = append(b.files, path)

	content, err := os.ReadFile(path)
	if err != nil {
		return err
	}

	lines := strings.Split(string(content), "\n")
	state := scanState{}
	for i, line := range lines {
		lineNumber := i + 1
		trimmed := strings.TrimSpace(stripLineComment(line))

		if state.inImportGroup {
			if trimmed == ")" {
				state.inImportGroup = false
				continue
			}
			b.addImport(path, line, trimmed, lineNumber)
			continue
		}

		if state.inTypeGroup {
			if trimmed == ")" {
				state.inTypeGroup = false
				continue
			}
			b.scanGroupedType(path, line, lineNumber)
			continue
		}

		if state.inStruct {
			if strings.HasPrefix(trimmed, "}") {
				state.inStruct = false
				continue
			}
			b.scanStructField(path, line, lineNumber)
			continue
		}

		if state.inServerBlock {
			if strings.HasPrefix(trimmed, "group:") {
				state.group = strings.Trim(strings.TrimSpace(strings.TrimPrefix(trimmed, "group:")), `"`)
			}
			if trimmed == ")" {
				state.inServerBlock = false
			}
			continue
		}

		switch {
		case trimmed == "import (":
			state.inImportGroup = true
		case strings.HasPrefix(trimmed, "import "):
			b.addImport(path, line, trimmed, lineNumber)
		case trimmed == "type (":
			state.inTypeGroup = true
		case strings.HasPrefix(trimmed, "type "):
			if b.scanTypeLine(path, line, lineNumber) && strings.Contains(line, "{") && !strings.Contains(line, "}") {
				state.inStruct = true
			}
		case strings.HasPrefix(trimmed, "@server"):
			state.group = ""
			state.inServerBlock = strings.Contains(trimmed, "(") && !strings.Contains(trimmed, ")")
		case strings.HasPrefix(trimmed, "@handler"):
			b.scanHandler(path, line, lineNumber, state.group)
		case isRouteLine(trimmed):
			b.scanRouteTypes(path, line, lineNumber)
		}
	}

	return nil
}

type scanState struct {
	group         string
	inImportGroup bool
	inServerBlock bool
	inStruct      bool
	inTypeGroup   bool
}

func (b *builder) addImport(currentFile, rawLine, trimmed string, line int) {
	value := ""
	if match := importLinePattern.FindStringSubmatch(rawLine); len(match) == 2 {
		value = match[1]
	} else if strings.HasPrefix(trimmed, `"`) {
		value = strings.Trim(trimmed, `"`)
	}
	if value == "" {
		return
	}

	targetFile := value
	if !filepath.IsAbs(targetFile) {
		targetFile = filepath.Join(filepath.Dir(currentFile), targetFile)
	}
	targetFile = filepath.Clean(targetFile)

	column := strings.Index(rawLine, value)
	if column < 0 {
		column = 0
	}
	b.jumps = append(b.jumps, rangeItem{
		Kind:      "import",
		Name:      value,
		File:      currentFile,
		Line:      line,
		Column:    column,
		EndColumn: column + len(value),
		Target: &target{
			File:   targetFile,
			Line:   1,
			Column: 0,
		},
	})

	if _, err := os.Stat(targetFile); err == nil {
		_ = b.parseFile(targetFile)
	}
}

func (b *builder) scanGroupedType(file, line string, lineNumber int) {
	if match := typeNamePattern.FindStringSubmatch(line); len(match) == 2 {
		name := match[1]
		b.addTypeDefinition(file, line, lineNumber, name)
		afterName := line[strings.Index(line, name)+len(name):]
		b.addTypeReferences(file, line, afterName, lineNumber)
	}
}

func (b *builder) scanTypeLine(file, line string, lineNumber int) bool {
	match := typeLinePattern.FindStringSubmatch(line)
	if len(match) != 2 {
		return false
	}

	name := match[1]
	b.addTypeDefinition(file, line, lineNumber, name)
	afterName := line[strings.Index(line, name)+len(name):]
	b.addTypeReferences(file, line, afterName, lineNumber)
	return true
}

func (b *builder) addTypeDefinition(file, line string, lineNumber int, name string) {
	column := strings.Index(line, name)
	if column < 0 {
		column = 0
	}
	if _, exists := b.defs[name]; !exists {
		b.defs[name] = target{
			File:   file,
			Line:   lineNumber,
			Column: column,
		}
	}
	b.symbols = append(b.symbols, rangeItem{
		Kind:      "type",
		Name:      name,
		File:      file,
		Line:      lineNumber,
		Column:    column,
		EndColumn: column + len(name),
	})
}

func (b *builder) scanStructField(file, line string, lineNumber int) {
	line = stripLineComment(line)
	beforeTag := strings.SplitN(line, "`", 2)[0]
	parts := strings.Fields(beforeTag)
	if len(parts) < 2 {
		return
	}

	fieldName := parts[0]
	start := strings.Index(beforeTag, fieldName)
	if start < 0 {
		return
	}
	typeText := beforeTag[start+len(fieldName):]
	b.addTypeReferences(file, line, typeText, lineNumber)
}

func (b *builder) scanHandler(file, line string, lineNumber int, group string) {
	match := handlerPattern.FindStringSubmatch(line)
	if len(match) != 2 {
		return
	}

	name := match[1]
	column := strings.Index(line, name)
	if column < 0 {
		column = 0
	}
	b.jumps = append(b.jumps, rangeItem{
		Kind:      "handler",
		Name:      name,
		File:      file,
		Line:      lineNumber,
		Column:    column,
		EndColumn: column + len(name),
		Group:     group,
	})
}

func (b *builder) scanRouteTypes(file, line string, lineNumber int) {
	for _, match := range routeTypePattern.FindAllStringSubmatchIndex(line, -1) {
		if len(match) < 4 {
			continue
		}
		name := line[match[2]:match[3]]
		b.addTypeReference(file, line, lineNumber, name, match[2])
	}
}

func (b *builder) addTypeReferences(file, rawLine, typeText string, lineNumber int) {
	baseColumn := strings.Index(rawLine, typeText)
	if baseColumn < 0 {
		baseColumn = 0
	}

	for _, match := range identifierPattern.FindAllStringIndex(typeText, -1) {
		name := typeText[match[0]:match[1]]
		if isBuiltInType(name) {
			continue
		}
		b.addTypeReference(file, rawLine, lineNumber, name, baseColumn+match[0])
	}
}

func (b *builder) addTypeReference(file, line string, lineNumber int, name string, column int) {
	if isBuiltInType(name) {
		return
	}
	b.jumps = append(b.jumps, rangeItem{
		Kind:      "type",
		Name:      name,
		File:      file,
		Line:      lineNumber,
		Column:    column,
		EndColumn: column + len(name),
	})
}

func (b *builder) resolveTypeTargets() {
	for i := range b.jumps {
		if b.jumps[i].Kind != "type" {
			continue
		}
		if def, exists := b.defs[b.jumps[i].Name]; exists {
			b.jumps[i].Target = &def
		}
	}
}

func stripLineComment(line string) string {
	if index := strings.Index(line, "//"); index >= 0 {
		return line[:index]
	}
	return line
}

func isRouteLine(line string) bool {
	for _, method := range []string{"get ", "post ", "put ", "delete ", "patch ", "head ", "options "} {
		if strings.HasPrefix(line, method) {
			return true
		}
	}
	return false
}

func isBuiltInType(name string) bool {
	return builtInTypes[name]
}
