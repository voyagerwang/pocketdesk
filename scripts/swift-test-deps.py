#!/usr/bin/env python3
# [INPUT]: 一个 tests/*.test.swift 路径；读取 Sources/*.swift（不含 main.swift）的顶层类型声明。
# [OUTPUT]: 打印该测试的编译方式：FULL（与整套 Sources 一起编，不自带替身），或 SUBSET 加需要的源文件列表（测试自带替身时，
#           按代码里真实引用的类型做闭包，排除声明了被替身类型的源文件）。
# [POS]: scripts/run-swift-tests.sh 的编译清单生成器；每次运行现算，源文件增删不用手改清单。
# [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
import glob, os, re, sys

DECL = re.compile(r'^(?:@\w+\s+)*(?:public |private |fileprivate |internal |final )*(?:enum|struct|class|protocol|typealias|actor)\s+([A-Za-z_]\w*)', re.M)

def code(text):
    """只看代码：去掉注释和字符串字面量，免得注释里提到的类型把无关文件拉进来。"""
    text = re.sub(r'/\*.*?\*/', '', text, flags=re.S)
    text = re.sub(r'//[^\n]*', '', text)
    return re.sub(r'"(?:[^"\\\n]|\\.)*"', '""', text)

def main(test, root):
    sources = {}
    for path in sorted(glob.glob(os.path.join(root, 'Sources', '*.swift'))):
        if os.path.basename(path) != 'main.swift':
            sources[os.path.basename(path)] = open(path, encoding='utf-8').read()
    owner = {}
    for name, text in sources.items():
        for declared in DECL.findall(text):
            owner.setdefault(declared, set()).add(name)
    test_text = open(test, encoding='utf-8').read()
    stubs = {name for name in DECL.findall(test_text) if name in owner}
    if not stubs:
        print('FULL'); return
    banned = {f for name in stubs for f in owner[name]}
    stripped = {name: code(text) for name, text in sources.items()}
    included, todo = set(), [None]
    while todo:
        current = todo.pop()
        text = code(test_text) if current is None else stripped[current]
        for name, files in owner.items():
            if name in stubs or not re.search(r'\b' + re.escape(name) + r'\b', text):
                continue
            for f in files:
                if f not in included and f not in banned:
                    included.add(f); todo.append(f)
    print('SUBSET ' + ' '.join(sorted(included)))

if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else os.getcwd())
