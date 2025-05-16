#!/bin/sh
# Find all JS files in the nginx html directory
find /usr/share/nginx/html -type f -name "*.js" -exec grep -l "localhost:5000" {} \; | while read file; do
    echo "Modifying \"
    # Replace localhost:5000 with our backend IP
    sed -i 's|localhost:5000|72.145.47.178:5000|g' \
done
echo "Modification complete"
