if exists("b:current_syntax")
  finish
endif

syntax keyword goctlApiKeyword syntax info import type service returns
syntax keyword goctlApiType any bool byte complex64 complex128 error float32 float64 int int8 int16 int32 int64 rune string uint uint8 uint16 uint32 uint64 uintptr
syntax keyword goctlApiHttpMethod get post put delete patch head options
syntax match goctlApiAnnotation /@\%(server\|handler\|doc\)\>/
syntax match goctlApiPath /\s\/[A-Za-z0-9_\/:.-]*/
syntax match goctlApiFieldTag /`[^`]*`/
syntax region goctlApiString start=/"/ skip=/\\"/ end=/"/
syntax region goctlApiRawString start=/`/ end=/`/
syntax match goctlApiLineComment /\/\/.*/
syntax region goctlApiBlockComment start=/\/\*/ end=/\*\//

highlight default link goctlApiKeyword Keyword
highlight default link goctlApiType Type
highlight default link goctlApiHttpMethod Function
highlight default link goctlApiAnnotation PreProc
highlight default link goctlApiPath String
highlight default link goctlApiFieldTag Special
highlight default link goctlApiString String
highlight default link goctlApiRawString String
highlight default link goctlApiLineComment Comment
highlight default link goctlApiBlockComment Comment

let b:current_syntax = "goctlapi"
