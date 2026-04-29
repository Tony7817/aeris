package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	goctlast "github.com/zeromicro/go-zero/tools/goctl/pkg/parser/api/ast"
	goctlparser "github.com/zeromicro/go-zero/tools/goctl/pkg/parser/api/parser"
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
	lines   map[string][]string
	defs    map[string]target
	jumps   []rangeItem
	symbols []rangeItem
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
		lines:   make(map[string][]string),
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
	if err := b.loadLines(path); err != nil {
		return err
	}

	parser := goctlparser.New(path, nil)
	parsed := parser.Parse()
	if err := parser.CheckErrors(); err != nil {
		return err
	}
	if parsed == nil {
		return fmt.Errorf("failed to parse %s", path)
	}

	for _, stmt := range parsed.Stmts {
		switch value := stmt.(type) {
		case *goctlast.ImportLiteralStmt:
			if err := b.addImport(path, value.Value); err != nil {
				return err
			}
		case *goctlast.ImportGroupStmt:
			for _, imported := range value.Values {
				if err := b.addImport(path, imported); err != nil {
					return err
				}
			}
		case *goctlast.TypeLiteralStmt:
			b.addTypeDefinition(path, value.Expr)
			b.addDataTypeReferences(path, value.Expr.DataType)
		case *goctlast.TypeGroupStmt:
			for _, expr := range value.ExprList {
				b.addTypeDefinition(path, expr)
				b.addDataTypeReferences(path, expr.DataType)
			}
		case *goctlast.ServiceStmt:
			b.addServiceReferences(path, value)
		}
	}

	return nil
}

func (b *builder) addImport(currentFile string, node *goctlast.TokenNode) error {
	if node == nil {
		return nil
	}
	value := tokenText(node)
	if value == "" {
		return nil
	}

	targetFile := value
	if !filepath.IsAbs(targetFile) {
		targetFile = filepath.Join(filepath.Dir(currentFile), targetFile)
	}
	targetFile = filepath.Clean(targetFile)

	b.jumps = append(b.jumps, rangeItem{
		Kind:      "import",
		Name:      value,
		File:      currentFile,
		Line:      b.tokenLine(node),
		Column:    b.tokenColumn(currentFile, node),
		EndColumn: b.tokenEndColumn(currentFile, node),
		Target: &target{
			File:   targetFile,
			Line:   1,
			Column: 0,
		},
	})

	if _, err := os.Stat(targetFile); err == nil {
		return b.parseFile(targetFile)
	}
	return nil
}

func (b *builder) addTypeDefinition(file string, expr *goctlast.TypeExpr) {
	if expr == nil || expr.Name == nil {
		return
	}
	name := expr.Name.Token.Text
	if name == "" {
		return
	}
	line := b.tokenLine(expr.Name)
	column := b.tokenColumn(file, expr.Name)
	if _, exists := b.defs[name]; !exists {
		b.defs[name] = target{
			File:   file,
			Line:   line,
			Column: column,
		}
	}
	b.symbols = append(b.symbols, rangeItem{
		Kind:      "type",
		Name:      name,
		File:      file,
		Line:      line,
		Column:    column,
		EndColumn: b.tokenEndColumn(file, expr.Name),
	})
}

func (b *builder) addServiceReferences(file string, stmt *goctlast.ServiceStmt) {
	if stmt == nil {
		return
	}

	group := atServerValue(stmt.AtServerStmt, "group")
	for _, item := range stmt.Routes {
		if item == nil {
			continue
		}
		if item.AtHandler != nil && item.AtHandler.Name != nil {
			node := item.AtHandler.Name
			b.jumps = append(b.jumps, rangeItem{
				Kind:      "handler",
				Name:      node.Token.Text,
				File:      file,
				Line:      b.tokenLine(node),
				Column:    b.tokenColumn(file, node),
				EndColumn: b.tokenEndColumn(file, node),
				Group:     group,
			})
		}
		if item.Route == nil {
			continue
		}
		b.addBodyReference(file, item.Route.Request)
		b.addBodyReference(file, item.Route.Response)
	}
}

func (b *builder) addBodyReference(file string, body *goctlast.BodyStmt) {
	if body == nil || body.Body == nil || body.Body.Value == nil {
		return
	}
	node := body.Body.Value
	if isBuiltInType(node.Token.Text) {
		return
	}
	b.jumps = append(b.jumps, rangeItem{
		Kind:      "type",
		Name:      node.Token.Text,
		File:      file,
		Line:      b.tokenLine(node),
		Column:    b.tokenColumn(file, node),
		EndColumn: b.tokenEndColumn(file, node),
	})
}

func (b *builder) addDataTypeReferences(file string, dataType goctlast.DataType) {
	switch value := dataType.(type) {
	case *goctlast.BaseDataType:
		if !isBuiltInType(value.Base.Token.Text) {
			b.addTypeReference(file, value.Base)
		}
	case *goctlast.PointerDataType:
		b.addDataTypeReferences(file, value.DataType)
	case *goctlast.ArrayDataType:
		b.addDataTypeReferences(file, value.DataType)
	case *goctlast.SliceDataType:
		b.addDataTypeReferences(file, value.DataType)
	case *goctlast.MapDataType:
		b.addDataTypeReferences(file, value.Key)
		b.addDataTypeReferences(file, value.Value)
	case *goctlast.StructDataType:
		for _, elem := range value.Elements {
			b.addDataTypeReferences(file, elem.DataType)
		}
	}
}

func (b *builder) addTypeReference(file string, node *goctlast.TokenNode) {
	if node == nil || node.Token.Text == "" {
		return
	}
	b.jumps = append(b.jumps, rangeItem{
		Kind:      "type",
		Name:      node.Token.Text,
		File:      file,
		Line:      b.tokenLine(node),
		Column:    b.tokenColumn(file, node),
		EndColumn: b.tokenEndColumn(file, node),
	})
}

func (b *builder) loadLines(file string) error {
	content, err := os.ReadFile(file)
	if err != nil {
		return err
	}
	b.lines[filepath.Clean(file)] = strings.Split(string(content), "\n")
	return nil
}

func (b *builder) tokenLine(node *goctlast.TokenNode) int {
	if node == nil {
		return 1
	}
	return node.Token.Position.Line
}

func (b *builder) tokenColumn(file string, node *goctlast.TokenNode) int {
	column, _ := b.tokenRange(file, node)
	return column
}

func (b *builder) tokenEndColumn(file string, node *goctlast.TokenNode) int {
	_, endColumn := b.tokenRange(file, node)
	return endColumn
}

func (b *builder) tokenRange(file string, node *goctlast.TokenNode) (int, int) {
	if node == nil {
		return 0, 0
	}

	line := node.Token.Position.Line
	raw := node.Token.Text
	if line > 0 {
		lines := b.lines[filepath.Clean(file)]
		if line <= len(lines) {
			if column, endColumn, ok := locateTokenInLine(lines[line-1], raw, node.Token.Position.Column); ok {
				return column, endColumn
			}
			if text := tokenText(node); text != "" && text != raw {
				if column, endColumn, ok := locateTokenInLine(lines[line-1], text, node.Token.Position.Column); ok {
					return column, endColumn
				}
			}
		}
	}

	column := node.Token.Position.Column - 1
	if column < 0 {
		column = 0
	}
	return column, column + len(raw)
}

func locateTokenInLine(line, token string, reportedColumn int) (int, int, bool) {
	if token == "" {
		return 0, 0, false
	}

	best := -1
	bestDistance := 0
	for offset := 0; ; {
		index := strings.Index(line[offset:], token)
		if index < 0 {
			break
		}
		column := offset + index
		distance := min(abs(column-reportedColumn), abs(column-(reportedColumn-1)))
		if best < 0 || distance < bestDistance {
			best = column
			bestDistance = distance
		}
		offset = column + len(token)
	}

	if best < 0 {
		return 0, 0, false
	}
	return best, best + len(token), true
}

func abs(value int) int {
	if value < 0 {
		return -value
	}
	return value
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

func atServerValue(stmt *goctlast.AtServerStmt, key string) string {
	if stmt == nil {
		return ""
	}
	for _, item := range stmt.Values {
		if item.Key != nil && item.Value != nil && item.Key.Token.Text == key {
			return tokenText(item.Value)
		}
	}
	return ""
}

func tokenText(node *goctlast.TokenNode) string {
	if node == nil {
		return ""
	}
	text := node.Token.Text
	if unquoted, err := strconv.Unquote(text); err == nil {
		return unquoted
	}
	return strings.Trim(text, "`\"")
}

func isBuiltInType(name string) bool {
	return name == "any" || name == "interface{}" || goctlparser.IsBaseType(name)
}
