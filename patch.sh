sed -i '' 's/double gPhysicalW = 1179.0;/double gScreenScale = 3.0;/g' /Users/trieudz/Desktop/Test/IOSControlDaemon.m
sed -i '' 's/double gPhysicalH = 2556.0;//g' /Users/trieudz/Desktop/Test/IOSControlDaemon.m
sed -i '' 's/gPhysicalW = atof(argv\[3\]);/gScreenScale = atof(argv[3]);/g' /Users/trieudz/Desktop/Test/IOSControlDaemon.m
sed -i '' 's/gPhysicalH = atof(argv\[4\]);/ /g' /Users/trieudz/Desktop/Test/IOSControlDaemon.m
sed -i '' 's/gPhysicalW = gScreenW \* 2.0;/gScreenScale = 2.0;/g' /Users/trieudz/Desktop/Test/IOSControlDaemon.m
sed -i '' 's/gPhysicalH = gScreenH \* 2.0;//g' /Users/trieudz/Desktop/Test/IOSControlDaemon.m
sed -i '' 's/Physical: %.0f×%.0f/Scale: %.1f/g' /Users/trieudz/Desktop/Test/IOSControlDaemon.m
sed -i '' 's/, gPhysicalW, gPhysicalH/, gScreenScale/g' /Users/trieudz/Desktop/Test/IOSControlDaemon.m
