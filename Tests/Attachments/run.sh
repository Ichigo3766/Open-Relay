#!/bin/sh
set -eu
# Pass an external artifact directory; no generated files enter the checkout.
work=${1:?Usage: sh Tests/Attachments/run.sh /path/to/artifacts}
mkdir -p "$work"
for suite in RegressionTests ContextTests; do
    xcrun swiftc -o "$work/$suite" "Tests/Attachments/$suite.swift" \
        'Open UI/Core/Models/ChatMessage.swift' \
        'Open UI/Core/Models/MessageHistory.swift' \
        'Open UI/Core/Models/KnowledgeItem.swift'
    "$work/$suite"
done
