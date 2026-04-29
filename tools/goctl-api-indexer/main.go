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
	Files []string    `json:"files"`
	Jumps []rangeItem `json:"jumps"`
}

type builder struct {
	visited map[string]bool
	files   []string
	defs    map[string]target
	jumps   []rangeItem
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
		Files: b.files,
		Jumps: b.jumps,
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
		Line:      node.Token.Position.Line,
		Column:    node.Token.Position.Column,
		EndColumn: node.Token.Position.Column + len([]rune(node.Token.Text)),
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
	pos := expr.Name.Token.Position
	if _, exists := b.defs[name]; !exists {
		b.defs[name] = target{
			File:   file,
			Line:   pos.Line,
			Column: pos.Column,
		}
	}
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
				Line:      node.Token.Position.Line,
				Column:    node.Token.Position.Column,
				EndColumn: node.Token.Position.Column + len([]rune(node.Token.Text)),
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
		Line:      node.Token.Position.Line,
		Column:    node.Token.Position.Column,
		EndColumn: node.Token.Position.Column + len([]rune(node.Token.Text)),
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
		Line:      node.Token.Position.Line,
		Column:    node.Token.Position.Column,
		EndColumn: node.Token.Position.Column + len([]rune(node.Token.Text)),
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
